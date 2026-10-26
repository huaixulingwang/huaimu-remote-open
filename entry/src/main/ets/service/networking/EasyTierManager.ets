import et from 'easytier-ohrs';
import { Logger } from '../../common/Logger';
import { PreferencesUtil } from '../../utils/PreferencesUtil';
import { Secrets } from '../../common/Secrets';
import { FileLog } from './FileLog';
import { NetworkIdentity } from './NetworkIdentity';

const TAG = 'EasyTierManager';

/**
 * EasyTier 组网管理器（55f15bb 老版 SDK + 老版实例流程）
 *
 * 【关键时序】引擎 Instance::run() 的启动流程里会无条件把网卡换成 mock nic
 * （只吃包、不读 TUN），移动端不会重建。所以 setTunFd 必须发生在这次清理之后，
 * 否则真网卡会被 mock 顶掉 —— 系统侧看起来就是"包进了 TUN 却没人读"，
 * 数据面永久死亡且没有任何报错。
 *
 * 正确顺序：startEngine() → waitEngineReady() → 再建 TUN → attachTunFd()（只挂一次）
 *
 * 注意：必须用静态 import，动态 import 无法加载 SDK 里的原生库
 */
export class EasyTierManager {
  private static instance: EasyTierManager;
  private running: boolean = false;
  // SDK 只认 UUID 格式的实例 ID，run 起来后从 collectRunningNetwork() 拿
  private instId: string = '';
  // 引擎实际使用的虚拟 IP（优先取自引擎回报的 my_node_info.virtual_ipv4）
  private virtualIpv4: string = '';
  // 本次配置里写进去的虚拟 IP，作为引擎回报不可解析时的兜底
  private configuredIp: string = '';

  // 节点策略：默认只用自建会合节点。公共节点只在用户明确同意后临时启用，
  // 且始终配合 p2p_only（只与直连设备通信），保证任何服务器都碰不到画面数据。
  private static readonly HUB_PEER_TCP: string = 'tcp://hub.example.com:11010';
  private static readonly HUB_PEER_WSS: string = 'wss://hub.example.com:11012';
  private static readonly PUBLIC_PEER: string = 'tcp://et1.fuis.top:11010';
  private static readonly DEFAULT_NETWORK_NAME: string = 'open-remote-2026';
  // 平板专属虚拟 IP .3：避开外部 EasyTier App 的 .2（两者同网络，IP 必须错开）
  private static readonly DEFAULT_IP: string = '10.126.126.3';

  private constructor() {}

  static getInstance(): EasyTierManager {
    if (!EasyTierManager.instance) {
      EasyTierManager.instance = new EasyTierManager();
    }
    return EasyTierManager.instance;
  }

  /**
   * 第一步：只启动引擎，不挂 TUN。
   * 此时引擎靠物理网卡（WiFi/有线）连 peer，TUN 稍后再挂。
   */
  async startEngine(): Promise<boolean> {
    // 已经有实例在跑就直接复用（重连场景）
    if (this.instId) {
      try {
        if (et.isRunningNetwork(this.instId)) {
          FileLog.d(TAG, `engine already running: ${this.instId}`);
          return true;
        }
      } catch (_) {
      }
    }

    let step = 'check-sdk';
    try {
      FileLog.d(TAG, `SDK check: setTunFd=${typeof et.setTunFd}, runNetworkInstance=${typeof et.runNetworkInstance}, version=${et.easytierVersion()}`);

      // 原生日志钩子只做辅助，失败不能阻断组网
      step = 'init-log-hooks';
      try {
        et.hilogGlobalOptions(0xD001, 'EasyTier');
        et.initPanicHook();
        // tracing 诊断已完成核验（2026-10-19，mock-nic 时序竞态已修复），关闭以免刷屏吃性能
        FileLog.d(TAG, 'easytier native log hooks ok');
      } catch (hookErr) {
        FileLog.d(TAG, `easytier native log hooks failed: ${String(hookErr)} ${JSON.stringify(hookErr)}`);
      }

      // 1. 构建配置
      step = 'build-config';
      const cfg = await this.buildConfig();
      FileLog.d(TAG, `config length: ${cfg.length}`);
      if (!cfg) {
        FileLog.d(TAG, 'config empty');
        return false;
      }

      // 2. 启动实例（此时还没有虚拟网卡）
      step = 'run-network-instance';
      let ok = et.runNetworkInstance(cfg);
      FileLog.d(TAG, `runNetworkInstance result: ${ok}`);
      if (!ok) {
        // 可能有残留实例没停干净，先清掉再重试一次
        const existing = et.collectRunningNetwork();
        FileLog.d(TAG, `run failed, existing instances: ${JSON.stringify(existing)}`);
        if (existing.length > 0) {
          et.stopNetworkInstance(existing);
          FileLog.d(TAG, 'stopped leftover instances, retry run');
          ok = et.runNetworkInstance(cfg);
          FileLog.d(TAG, `runNetworkInstance retry result: ${ok}`);
        }
        if (!ok) {
          return false;
        }
      }

      // 3. 拿到实例 UUID
      step = 'get-instance-id';
      const ids = et.collectRunningNetwork();
      FileLog.d(TAG, `running instances: ${JSON.stringify(ids)}`);
      if (ids.length === 0) {
        FileLog.d(TAG, 'no running instance after run');
        return false;
      }
      this.instId = ids[0];
      this.running = true;
      FileLog.d(TAG, `engine started, instId=${this.instId} (TUN NOT attached yet)`);
      return true;
    } catch (e) {
      FileLog.d(TAG, `startEngine error at ${step}: ${String(e)} ${JSON.stringify(e)}`);
      Logger.error(TAG, `startEngine error at ${step}: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 第二步：等引擎真正就绪（Instance::run() 已走完内部清网卡步骤）再挂 TUN。
   *
   * 判定：轮询 collectNetworkInfos()，出现 peers 即认为已过清理窗口；
   * 另外强制最少等 MIN_WAIT_MS（与日志证据对齐：清理发生在实例创建后几毫秒内），
   * 即使解析失败也不会挂太早。到 PEER_WAIT_MAX_MS 无论是否解析出 peers 都放行。
   */
  async waitEngineReady(): Promise<void> {
    const MIN_WAIT_MS = 3000;
    const PEER_WAIT_MAX_MS = 8000;
    const HARD_MAX_MS = 20000;
    const t0 = Date.now();
    let rawLogged = false;

    while (true) {
      const info = this.readInfos();
      if (!rawLogged) {
        FileLog.d(TAG, `netinfo raw[first]: ${info.raw}`);
        rawLogged = true;
      }
      if (info.virtualIpv4) {
        this.virtualIpv4 = info.virtualIpv4;
      }
      const elapsed = Date.now() - t0;
      FileLog.d(TAG, `waitReady t=${Math.round(elapsed / 1000)}s vip=${info.virtualIpv4 ? info.virtualIpv4 : '-'} peers=${info.peerCount}`);
      if (elapsed >= MIN_WAIT_MS && (info.peerCount > 0 || elapsed >= PEER_WAIT_MAX_MS)) {
        FileLog.d(TAG, `engine ready: peers=${info.peerCount} elapsed=${elapsed}ms`);
        break;
      }
      if (elapsed >= HARD_MAX_MS) {
        FileLog.d(TAG, `engine ready hard-timeout at ${elapsed}ms (proceed anyway)`);
        break;
      }
      await this.sleep(250);
    }
    // 再留一点余量，确保已越过 run() 的清理点
    await this.sleep(400);
  }

  /** 建 TUN 时使用的虚拟 IP：优先引擎回报值，否则用配置值（两者本就应一致） */
  getVirtualIpv4(): string {
    return this.virtualIpv4 ? this.virtualIpv4 : this.configuredIp;
  }

  /**
   * 第三步：把 VPN 的 TUN fd 挂到实例上（引擎就绪后调用，只调一次）
   */
  async attachTunFd(fd: number): Promise<boolean> {
    if (!this.instId) {
      FileLog.d(TAG, 'attachTunFd: no instId');
      return false;
    }
    try {
      const ok = et.setTunFd(this.instId, fd);
      FileLog.d(TAG, `attachTunFd(${this.instId}, fd=${fd}) result: ${ok}`);
      Logger.info(TAG, `attachTunFd result: ${ok}`);
      return ok;
    } catch (e) {
      FileLog.d(TAG, `attachTunFd error: ${String(e)} ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 停止组网
   */
  async stop(): Promise<void> {
    try {
      // SDK 的 stop 也只认 UUID，直接停掉所有正在跑的实例
      const ids = et.collectRunningNetwork();
      FileLog.d(TAG, `stop: APP-INITIATED engine stop, instances=${JSON.stringify(ids)}`);
      if (ids.length > 0) {
        et.stopNetworkInstance(ids);
      }
      this.running = false;
      this.instId = '';
      this.virtualIpv4 = '';
      Logger.info(TAG, 'EasyTier stopped');
    } catch (e) {
      Logger.error(TAG, `stop error: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 检查组网是否在运行（SDK 只允许单实例，直接看有没有在跑的）
   */
  async isRunning(): Promise<boolean> {
    try {
      const ids = et.collectRunningNetwork();
      if (this.instId) {
        return ids.includes(this.instId);
      }
      return ids.length > 0;
    } catch (e) {
      return false;
    }
  }

  /**
   * 把引擎实时网络状态压成一行写入持久化日志
   */
  dumpNetworkInfosToLog(label: string): void {
    try {
      const info = this.readInfos();
      FileLog.d(TAG, `netinfos[${label}]: vip=${info.virtualIpv4 ? info.virtualIpv4 : '-'} peers=${info.peerCount} | ${info.raw}`);
      // 解析失败时把实例 JSON 的顶层字段名一并记下，便于核对真实结构（勿长期保留）
      if (!info.virtualIpv4 || info.peerCount === 0) {
        FileLog.d(TAG, `netinfos[${label}] parse-miss: topKeys=${info.topKeys ? info.topKeys : '(none)'}`);
      }
    } catch (e) {
      FileLog.d(TAG, `netinfos[${label}] error: ${String(e)}`);
    }
  }

  /** 读取引擎网络状态：虚拟 IP + peer 数量 + 原始串（便于核验字段名） */
  private readInfos(): NetworkInfoSummary {
    const rawParts: string[] = [];
    let virtualIpv4 = '';
    let peerCount = 0;
    let topKeys = '';
    try {
      const infos = et.collectNetworkInfos();
      for (const kv of infos) {
        const rawValue = kv.value ? kv.value : '';
        const shown = rawValue.length > 800 ? rawValue.substring(0, 800) + '...' : rawValue;
        rawParts.push(`${kv.key}=${shown}`);
        // SDK 实际返回的是"实例 UUID -> 该实例状态 JSON"，my_node_info / peers 都嵌在这一层
        // JSON 里。早前按扁平 key（key === 'my_node_info'）匹配，所以 vip 恒为 -、peers 恒为 0。
        if (kv.key === 'my_node_info') {
          const ip = EasyTierManager.extractVirtualIpv4(rawValue);
          if (ip) {
            virtualIpv4 = ip;
          }
        } else if (kv.key === 'peers') {
          peerCount = EasyTierManager.countPeers(rawValue);
        } else {
          const ip = EasyTierManager.extractVirtualIpv4(rawValue);
          if (ip) {
            virtualIpv4 = ip;
          }
          const n = EasyTierManager.countPeers(rawValue);
          if (n > peerCount) {
            peerCount = n;
          }
          if (!topKeys && rawValue.startsWith('{')) {
            topKeys = `${kv.key}: ${EasyTierManager.topLevelKeys(rawValue)}`;
          }
        }
      }
    } catch (e) {
      FileLog.d(TAG, `readInfos error: ${String(e)}`);
    }
    return { virtualIpv4: virtualIpv4, peerCount: peerCount, topKeys: topKeys, raw: rawParts.join(' | ') };
  }

  /** 取实例状态 JSON 的顶层字段名（诊断用，确认 peers / my_node_info 的真实位置） */
  private static topLevelKeys(json: string): string {
    try {
      const parsed = JSON.parse(json) as Object;
      if (Array.isArray(parsed)) {
        return 'array';
      }
      return Object.keys(parsed as Record<string, Object>).join(',');
    } catch (_) {
      return 'unparsed';
    }
  }

  /**
   * 取 virtual_ipv4，兼容两种形态：
   *  - "virtual_ipv4":"10.126.126.3"
   *  - "virtual_ipv4":{"address":{"addr":176061955},...}  ← Rust 侧按 u32 输出，需转点分十进制
   */
  private static extractVirtualIpv4(json: string): string {
    const asString = /"virtual_ipv4"\s*:\s*"([0-9.]+)"/.exec(json);
    if (asString && asString[1]) {
      return asString[1];
    }
    const asNum = /"virtual_ipv4"\s*:\s*\{[\s\S]*?"addr"\s*:\s*(\d+)/.exec(json);
    if (asNum && asNum[1]) {
      const v = Number.parseInt(asNum[1], 10);
      return `${(v >>> 24) & 0xff}.${(v >>> 16) & 0xff}.${(v >>> 8) & 0xff}.${v & 0xff}`;
    }
    return '';
  }

  /** peers 可能在实例 JSON 顶层，也可能是旧版扁平形态的集合本身；找不到就记 0，不猜 */
  private static countPeers(json: string): number {
    try {
      const parsed = JSON.parse(json) as Object;
      if (Array.isArray(parsed)) {
        return (parsed as Object[]).length;
      }
      const nested = (parsed as Record<string, Object>).peers;
      if (Array.isArray(nested)) {
        return (nested as Object[]).length;
      }
      if (nested) {
        return Object.keys(nested as Record<string, Object>).length;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 构建 EasyTier JSON 配置
   * 与 15:30 真成功时完全一致（无 flags 段），优先用本地偏好，否则默认值
   */
  private async buildConfig(): Promise<string> {
    let netName: string = EasyTierManager.DEFAULT_NETWORK_NAME;
    let netSecret: string = Secrets.EASYTIER_NETWORK_SECRET;
    let ip: string = EasyTierManager.DEFAULT_IP;
    try {
      // 与账号中心里 AccountCenterService 的 KEY_ACCOUNT_ID 同一个键：
      // 登录后只加入这个账号的专属网络，不同账号之间彻底隔离。
      const accountId: string = await PreferencesUtil.get<string>('account_id', '');
      if (accountId.length > 0) {
        netName = NetworkIdentity.deriveName(accountId);
        netSecret = NetworkIdentity.deriveSecret(accountId);
      } else {
        netName = await PreferencesUtil.get<string>('et_network_name', EasyTierManager.DEFAULT_NETWORK_NAME);
        netSecret = await PreferencesUtil.get<string>('et_network_secret', Secrets.EASYTIER_NETWORK_SECRET);
      }
      ip = await PreferencesUtil.get<string>('et_ip', EasyTierManager.DEFAULT_IP);
    } catch (prefErr) {
      FileLog.d(TAG, `preferences read failed, fallback to defaults: ${String(prefErr)}`);
    }
    this.configuredIp = ip;

    // 节点模式由 VpnController 在连接前问过用户：hub=只用自建，public=用户同意临时用公共节点
    let nodeMode: string = 'hub';
    try {
      nodeMode = await PreferencesUtil.get<string>('node_mode', 'hub');
    } catch (_) {
    }
    const peers: string[] = [EasyTierManager.HUB_PEER_TCP, EasyTierManager.HUB_PEER_WSS];
    if (nodeMode === 'public') {
      peers.push(EasyTierManager.PUBLIC_PEER);
    }

    const header: string = `ipv4 = "${ip}"\n\n[network_identity]\nnetwork_name = "${netName}"\n`
      + `network_secret = "${netSecret}"\n\n`;
    const peerToml: string = peers.map((p: string): string => `[[peer]]\nuri = "${p}"\n`).join('\n');
    const toml: string = header + peerToml;

    FileLog.d(TAG, `toml config: ipv4=${ip}, net=${netName}, mode=${nodeMode}, peers=${peers.length}, secret=${netSecret ? '***' : 'EMPTY'}`);

    // 优先带 flags：p2p_only 从机制上禁止任何服务器替我们转发数据
    const tomlWithFlags: string = toml + '\n[flags]\np2p_only = true\n';
    try {
      const jsonWithFlags = et.convertTomlToNetworkConfig(tomlWithFlags);
      if (jsonWithFlags) {
        FileLog.d(TAG, 'config built with flags: p2p_only=true');
        return jsonWithFlags;
      }
    } catch (e) {
      Logger.warn(TAG, `convert with flags failed: ${JSON.stringify(e)}`);
    }

    // 兜底：个别 SDK 版本不认 [flags] 段时，退回到不带该段的配置，保证组网不整体失效
    try {
      const json = et.convertTomlToNetworkConfig(toml);
      if (json) {
        FileLog.d(TAG, 'config built WITHOUT flags (p2p_only unavailable)');
        return json;
      }
    } catch (e2) {
      Logger.warn(TAG, `convertTomlToNetworkConfig error: ${JSON.stringify(e2)}`);
    }
    FileLog.d(TAG, 'config build failed (both with and without flags)');

    return '';
  }
}

/** 引擎网络状态摘要 */
interface NetworkInfoSummary {
  virtualIpv4: string;
  peerCount: number;
  /** 实例 JSON 的顶层字段名（诊断用） */
  topKeys: string;
  raw: string;
}
