import { vpnExtension, socket, connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../../common/Logger';
import { EasyTierManager } from './EasyTierManager';
import { FileLog } from './FileLog';
import { AccountCenterService } from '../account/AccountCenterService';
import { PreferencesUtil } from '../../utils/PreferencesUtil';

const TAG = 'VpnController';
const VPN_EXT_NAME = 'LingWangVpnExtensionAbility';
const STOP_DELAY_MS = 5 * 60 * 1000; // 断开后保持 5 分钟再关
// 自建会合节点：只帮牵线，不转发数据
const HUB_HOST = 'hub.example.com';
const HUB_PORT = 11010;
// 弱网/复杂 NAT 下，中继或 P2P 建立偶尔需要 30 秒以上；
// 实测一次成功约 4 秒，但曾出现 27 秒整仍未通、随后手动重试即成功的情况。
// 单轮给 60 秒，失败后自动完整重来 1 轮（等价于系统替用户再点一次）。
const READY_TIMEOUT_MS = 60000;
const MAX_ATTEMPTS = 2;

// 电脑在虚拟网络里的固定地址（产品约定：电脑 .1，平板 .2）
export const HOST_VIRTUAL_IP = '10.126.126.1';
const SUNSHINE_HTTPS_PORT = 47984;
// 平板自己专属的虚拟地址：只有它落在网卡上，才说明"我们自己的组网"真的起来了
const OWN_VIRTUAL_IP = '10.126.126.3';

/**
 * 自建会合节点是否连得上：只探端口，不传任何业务数据
 */
function probeHubReachable(timeoutMs: number): Promise<boolean> {
  return new Promise((resolve: (ok: boolean) => void) => {
    const tcp = socket.constructTCPSocketInstance();
    let settled = false;
    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        tcp.close();
      } catch (_) {
      }
      resolve(ok);
    };
    tcp.connect({ address: { address: HUB_HOST, port: HUB_PORT }, timeout: timeoutMs })
      .then(() => finish(true))
      .catch(() => finish(false));
  });
}

/**
 * TCP 探测电脑是否可达（数据面真实验证）
 * 比查询组网进程状态更可靠：能连上 Sunshine 端口 = 虚拟网卡+组网+路由+电脑端全部就绪
 */
function probeHostReachable(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve: (ok: boolean) => void) => {
    const tcp = socket.constructTCPSocketInstance();
    let settled = false;
    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        tcp.close();
      } catch (_) {
      }
      resolve(ok);
    };
    tcp.connect({ address: { address: host, port: port }, timeout: timeoutMs })
      .then(() => finish(true))
      .catch(() => finish(false));
  });
}

/**
 * 绑定到 vpn-tun 网络的对照探测：系统默认路由不选 VPN 时，强制把探测 socket
 * 挂到 VPN 网络上再试。任一探测成功即视为数据面就绪（探明哪条路通，写入日志）。
 */
function probeHostBound(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve: (ok: boolean) => void) => {
    (async (): Promise<void> => {
      const tcp = socket.constructTCPSocketInstance();
      let settled = false;
      const finish = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          tcp.close();
        } catch (_) {
        }
        resolve(ok);
      };
      try {
        const nets: Array<connection.NetHandle> = await connection.getAllNets();
        let vpnNet: connection.NetHandle | null = null;
        for (const n of nets) {
          try {
            const prop: connection.ConnectionProperties = await connection.getConnectionProperties(n);
            const hasVip = (prop.linkAddresses || []).some((a: connection.LinkAddress) =>
              a.address && a.address.address === '10.126.126.3');
            if (hasVip) {
              vpnNet = n;
              FileLog.d(TAG, `boundProbe: vpn net found id=${n.netId} iface=${prop.interfaceName}`);
              break;
            }
          } catch (_) {
          }
        }
        if (vpnNet === null) {
          FileLog.d(TAG, 'boundProbe: no vpn-tun net handle');
          finish(false);
          return;
        }
        await tcp.bind({ address: '10.126.126.3', port: 0, family: 1 });
        await vpnNet.bindSocket(tcp);
        tcp.connect({ address: { address: host, port: port }, timeout: timeoutMs })
          .then(() => finish(true))
          .catch(() => finish(false));
      } catch (e) {
        FileLog.d(TAG, `boundProbe setup error: ${JSON.stringify(e)}`);
        finish(false);
      }
    })();
  });
}

/**
 * 我们自己的数据面是否真的起来了：只有专属地址 10.126.126.3 落在网卡上才算。
 * 外部 EasyTier App 用的是同一网段（10.126.126.2），"能连上电脑"很可能只是
 * 借了它家的通道，不能当作我们的组网已经就绪，否则会误判成"已连接"而不去组网。
 */
async function ownVipPresent(): Promise<boolean> {
  try {
    const nets: Array<connection.NetHandle> = await connection.getAllNets();
    for (const n of nets) {
      try {
        const prop: connection.ConnectionProperties = await connection.getConnectionProperties(n);
        const hit = (prop.linkAddresses || []).some((a: connection.LinkAddress) =>
          a.address && a.address.address === OWN_VIRTUAL_IP);
        if (hit) {
          return true;
        }
      } catch (_) {
      }
    }
  } catch (_) {
  }
  return false;
}

/**
 * 系统 VPN 通道是否被别的工具占着（例如外部 EasyTier App）。
 * 鸿蒙同一时间只允许一个 VPN，占着的时候我们根本建不了自己的网卡。
 */
async function foreignVpnPresent(): Promise<boolean> {
  try {
    const nets: Array<connection.NetHandle> = await connection.getAllNets();
    for (const n of nets) {
      try {
        const prop: connection.ConnectionProperties = await connection.getConnectionProperties(n);
        const iface = prop.interfaceName || '';
        if (iface.indexOf('vpn') < 0) {
          continue;
        }
        const isOurs = (prop.linkAddresses || []).some((a: connection.LinkAddress) =>
          a.address && a.address.address === OWN_VIRTUAL_IP);
        if (!isOurs) {
          FileLog.d(TAG, `foreign vpn occupying channel: iface=${iface}`);
          return true;
        }
      } catch (_) {
      }
    }
  } catch (_) {
  }
  return false;
}

/**
 * VPN 生命周期控制器
 * 负责启动/停止 VPN Extension，并实现"延迟关闭"策略：
 * - 发起远控时启动 VPN+组网
 * - 断开后保持 5 分钟，期间重连无需重新组网
 * - 超时自动关闭，释放资源
 */
export class VpnController {
  private static instance: VpnController;
  private context: common.UIAbilityContext | null = null;
  private stopTimer: number | null = null;
  private starting: boolean = false;
  // 用户主动取消标记：等待循环每秒检查，命中后尽快退出并拆除 VPN
  private cancelled: boolean = false;
  // 上一次失败的可读原因（界面用来给用户一句能照着做的话）
  private lastFailureHint: string = '';
  // 连接进度回调（UI 弹框用）
  private progressListener: ((msg: string) => void) | null = null;
  // VPN 授权观察者：必须长期持有，绝不能被垃圾回收。
  // 系统实现里这个对象的销毁回调（DeleteVpnObserver/GetEventManager）存在悬空指针，
  // 一旦被 GC 回收到就会触发 SIGSEGV，表现为"平板上软件自己突然关停"。
  // 以前每次 start() 都在局部变量里新建一个、随后被回收，正是历次 CppCrash 的根因。
  private authObserver: vpnExtension.VpnObserver | null = null;

  /** 注册连接进度回调（UI 弹框用）；传 null 取消监听 */
  setProgressListener(cb: ((msg: string) => void) | null): void {
    this.progressListener = cb;
  }

  /** 用户主动取消连接：等待循环会尽快退出并拆除 VPN */
  cancelStart(): void {
    this.cancelled = true;
    FileLog.d(TAG, 'cancelStart called by user');
    Logger.info(TAG, 'VPN start cancelled by user');
  }

  /** 上一次连接流程是否被用户取消 */
  isCancelledByUser(): boolean {
    return this.cancelled;
  }

  /** 上一次失败的可读原因；空串表示没有特别说明 */
  getLastFailureHint(): string {
    return this.lastFailureHint;
  }

  private reportProgress(msg: string): void {
    if (this.progressListener) {
      try {
        this.progressListener(msg);
      } catch (_) {
        // 回调异常不能影响组网流程
      }
    }
  }

  private constructor() {}

  /**
   * 只创建一个 VPN 授权观察者并长期持有。
   * 反复创建会让旧对象进入 GC 队列，而系统的销毁回调有悬空指针缺陷，
   * 回收到就崩溃，所以这里做成"一次创建、终身复用"。
   */
  private ensureAuthObserver(): void {
    if (this.authObserver) {
      FileLog.d(TAG, 'VPN authorization observer reused (kept alive)');
      return;
    }
    try {
      const observer = vpnExtension.createVpnObserver();
      observer.onAuthorizationResult((granted: boolean) => {
        FileLog.d(TAG, `VPN authorization result: ${granted}`);
        Logger.info(TAG, `VPN authorization result: ${granted}`);
      });
      this.authObserver = observer;
      FileLog.d(TAG, 'VPN authorization observer registered');
    } catch (e) {
      FileLog.d(TAG, `VPN observer register skipped: ${JSON.stringify(e)}`);
    }
  }

  static getInstance(): VpnController {
    if (!VpnController.instance) {
      VpnController.instance = new VpnController();
    }
    return VpnController.instance;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    FileLog.init(ctx);
    FileLog.d(TAG, 'VpnController context set');
  }

  /**
   * 决定本次用哪个会合节点：
   *  - 自建节点通着 → 只用自建，并把之前临时开启的公共节点收起
   *  - 自建节点不通且用户上次已同意 → 沿用公共节点（不再打扰）
   *  - 自建节点不通且第一次遇到 → 弹窗让用户自己选
   * 返回 false 表示用户选择「暂不连接」。
   */
  private async ensureNodeMode(): Promise<boolean> {
    let mode = 'hub';
    try {
      mode = await PreferencesUtil.get<string>('node_mode', 'hub');
    } catch (_) {
    }
    const hubOk = await probeHubReachable(2500);
    FileLog.d(TAG, `node mode check: mode=${mode} hubOk=${hubOk}`);

    if (hubOk) {
      if (mode === 'public') {
        try {
          await PreferencesUtil.put('node_mode', 'hub');
        } catch (_) {
        }
        FileLog.d(TAG, 'hub reachable again, switch back to hub');
      }
      return true;
    }

    if (mode === 'public') {
      FileLog.d(TAG, 'hub still down, reuse user-approved public node');
      return true;
    }

    try {
      const res = await promptAction.showDialog({
        title: '连不上我们的会合节点',
        message: '是否改用公共节点继续？\n\n'
          + '· 公共节点由第三方提供，只用来帮设备互相找到\n'
          + '· 连接仍然只走设备直连，画面不会经过任何服务器\n\n'
          + '选「暂不连接」＝ 这次先不联网，稍后会自动再试自己的节点。',
        buttons: [
          { text: '用公共节点', color: '#007DFF' },
          { text: '暂不连接', color: '#666666' }
        ]
      });
      if (res.index === 0) {
        try {
          await PreferencesUtil.put('node_mode', 'public');
        } catch (_) {
        }
        FileLog.d(TAG, 'user agreed to use public node (punch only)');
        return true;
      }
      FileLog.d(TAG, 'user declined public node');
    } catch (e) {
      FileLog.d(TAG, `node mode dialog failed: ${String(e)}`);
    }
    return false;
  }

  /**
   * 启动 VPN + 组网（发起远控时调用）
   */
  async start(targetHost: string = HOST_VIRTUAL_IP): Promise<boolean> {
    FileLog.d(TAG, `start() called, target=${targetHost}`);
    this.cancelled = false;
    this.lastFailureHint = '';
    // 取消待执行的关闭
    if (this.stopTimer !== null) {
      clearTimeout(this.stopTimer);
      this.stopTimer = null;
    }

    // 已在运行则直接返回
    if (await EasyTierManager.getInstance().isRunning()) {
      FileLog.d(TAG, 'VPN already running');
      Logger.info(TAG, 'VPN already running');
      return true;
    }

    // 组网实例在 VPN Extension 独立进程里，主进程查不到 SDK 状态，
    // 这里用"我们自己的专有地址是否在网卡上"判断是否真的早已就绪。
    // 不能再只看"能连上电脑"：外部 EasyTier App 也走 10.126.126.0/24，
    // 那条通道能通会让我们误判成已组网，从而一直不起自己的组网。
    if (await ownVipPresent()) {
      if (await probeHostReachable(targetHost, SUNSHINE_HTTPS_PORT, 1500)) {
        FileLog.d(TAG, 'own data plane ready (vip .3 + host reachable), skip start');
        Logger.info(TAG, 'VPN data plane already ready');
        return true;
      }
      FileLog.d(TAG, 'own vip present but host unreachable, rebuild vpn');
    } else {
      FileLog.d(TAG, 'own vip absent, build our own vpn');
    }

    // 节点策略：自建会合节点连不上时，必须先问用户，绝不静默切到公共节点
    const nodeAllowed = await this.ensureNodeMode();
    if (!nodeAllowed) {
      FileLog.d(TAG, 'user declined public node, abort connect');
      Logger.info(TAG, 'user declined public node');
      this.cancelled = true;
      return false;
    }

    if (this.starting) {
      FileLog.d(TAG, 'VPN starting in progress, wait...');
      Logger.info(TAG, 'VPN starting in progress, wait...');
      return this.waitForReady(READY_TIMEOUT_MS, targetHost);
    }

    if (!this.context) {
      FileLog.d(TAG, 'context not set');
      Logger.error(TAG, 'context not set');
      return false;
    }

    this.starting = true;
    try {
      // 监听系统 VPN 授权结果（API 26+ 支持；不支持时忽略，不影响启动）
      this.ensureAuthObserver();

      // 最多自动尝试两轮：弱网下首轮中继/P2P 建立可能超时，
      // 完整重建一次（新扩展、新 TUN fd、新引擎实例）成功率显著更高
      let ok = false;
      for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
        if (this.cancelled) {
          break;
        }
        FileLog.d(TAG, `VPN attempt ${attempt}/${MAX_ATTEMPTS}: starting VPN extension...`);
        Logger.info(TAG, `VPN attempt ${attempt}/${MAX_ATTEMPTS}`);
        this.reportProgress(`正在建立安全通道…（第 ${attempt}/${MAX_ATTEMPTS} 次尝试）`);
        ok = await this.attemptOnce(attempt, targetHost);
        if (ok) {
          break;
        }
        if (attempt < MAX_ATTEMPTS && !this.cancelled) {
          FileLog.d(TAG, `attempt ${attempt} failed, full teardown before retry...`);
          this.reportProgress('首轮未打通，正在自动重来一轮…');
          await this.stopNow();
          await this.sleep(2000);
        }
      }

      FileLog.d(TAG, `VPN start result: ${ok}`);
      if (ok) {
        // 组网成功后探一次账号中心：若系统 DNS 被顶掉，门禁取令牌会失败，
        // 这里提前留下可读日志（不阻塞连接）
        AccountCenterService.probeReachable().catch(() => {});
      }
      if (!ok) {
        // 系统同一时间只允许一个 VPN：如果是被别的工具占着，给用户一句能照着做的话
        if (await foreignVpnPresent()) {
          this.lastFailureHint = 'VPN 通道被其他工具占用（例如外部 EasyTier），请先断开它再重试';
          FileLog.d(TAG, 'failed: vpn channel occupied by another app');
        }
        FileLog.d(TAG, 'VPN failed after all attempts, cleaning up VPN extension');
        // 关键：所有尝试都失败必须拆掉 VPN Extension 和空白 TUN，
        // 否则会占着系统唯一 VPN 通道，导致外部 EasyTier 等也无法组网
        await this.stopNow();
      }
      Logger.info(TAG, `VPN start result: ${ok}`);
      return ok;
    } catch (e) {
      FileLog.d(TAG, `start VPN error: ${JSON.stringify(e)}`);
      Logger.error(TAG, `start VPN error: ${JSON.stringify(e)}`);
      // 授权被拒/拉起异常时同样清理，避免 VPN 残留
      await this.stopNow();
      return false;
    } finally {
      this.starting = false;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 完整拉起一轮 VPN 扩展并等待数据面就绪
   */
  private async attemptOnce(attempt: number, targetHost: string): Promise<boolean> {
    try {
      // 启动 VPN Extension（首次系统会弹授权框；已授权后重建通常不再弹）
      await vpnExtension.startVpnExtensionAbility({
        bundleName: this.context!.abilityInfo.bundleName,
        abilityName: VPN_EXT_NAME
      });
      FileLog.d(TAG, `attempt ${attempt}: startVpnExtensionAbility called, waiting for ready...`);
      return await this.waitForReady(READY_TIMEOUT_MS, targetHost);
    } catch (e) {
      FileLog.d(TAG, `attempt ${attempt} error: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 停止 VPN（延迟执行）
   */
  scheduleStop(): void {
    if (this.stopTimer !== null) {
      clearTimeout(this.stopTimer);
    }
    // 诊断：把"App 主动收摊"记进文件日志，与扩展侧 onDestroy 对照即可区分
    // 是系统回收了 VPN 扩展，还是我们自己在断开串流后主动拆的
    FileLog.d(TAG, 'scheduleStop: APP-INITIATED teardown scheduled (5min delay)');
    this.stopTimer = setTimeout(async () => {
      FileLog.d(TAG, 'scheduleStop fired: APP-INITIATED teardown starts now');
      Logger.info(TAG, 'VPN stop timeout reached, stopping...');
      this.stopTimer = null;
      await this.stopNow();
    }, STOP_DELAY_MS);
  }

  /**
   * 立即停止
   */
  async stopNow(): Promise<void> {
    FileLog.d(TAG, 'stopNow: APP-INITIATED teardown (stop engine + stopVpnExtensionAbility)');
    try {
      await EasyTierManager.getInstance().stop();
      if (this.context) {
        await vpnExtension.stopVpnExtensionAbility({
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: VPN_EXT_NAME
        });
      }
      Logger.info(TAG, 'VPN stopped');
    } catch (e) {
      Logger.error(TAG, `stop error: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 等待组网就绪
   * 注意：组网实例运行在 VPN Extension 的独立进程里，主进程直接查 SDK 状态查不到，
   * 所以就绪标准以"能真实连上电脑 Sunshine 端口"为准（数据面探测），
   * SDK 进程内状态仅作同进程场景的快速通道。
   */
  private waitForReady(timeoutMs: number = READY_TIMEOUT_MS, targetHost: string = HOST_VIRTUAL_IP): Promise<boolean> {
    return new Promise((resolve: (ok: boolean) => void) => {
      const start = Date.now();
      let lastProgressLog = 0;
      const check = async (): Promise<void> => {
        if (this.cancelled) {
          FileLog.d(TAG, 'waitForReady: cancelled by user');
          resolve(false);
          return;
        }
        try {
          const running = await EasyTierManager.getInstance().isRunning();
          if (running) {
            FileLog.d(TAG, 'ready: SDK instance running in same process');
            resolve(true);
            return;
          }
          let reachable = false;
          // 只有我们自己的网卡在，默认路由探测的结果才算数，
          // 否则可能是外部 EasyTier 的通道（同网段）在帮我们应答
          if (await ownVipPresent()) {
            reachable = await probeHostReachable(targetHost, SUNSHINE_HTTPS_PORT, 2000);
          }
          if (!reachable) {
            // 默认路由探测失败 → 试绑定到 vpn-tun 网络的对照探测
            reachable = await probeHostBound(targetHost, SUNSHINE_HTTPS_PORT, 2000);
            if (reachable) {
              FileLog.d(TAG, 'ready: host reachable via BOUND probe (default route bypasses vpn-tun!)');
            }
          }
          if (reachable) {
            FileLog.d(TAG, `ready: host ${targetHost}:${SUNSHINE_HTTPS_PORT} reachable in ${Date.now() - start}ms`);
            Logger.info(TAG, 'VPN data plane ready (host reachable)');
            resolve(true);
            return;
          }
        } catch (e) {
          FileLog.d(TAG, `waitForReady check error: ${JSON.stringify(e)}`);
        }
        const elapsed = Date.now() - start;
        // 每 10 秒落盘一次等待进度（引擎侧的 peer 状态由扩展进程同时段记录）
        if (elapsed - lastProgressLog >= 5000) {
          lastProgressLog = elapsed;
          FileLog.d(TAG, `waiting for data plane... ${Math.round(elapsed / 1000)}s, host not reachable yet`);
          this.reportProgress(`仍在等待电脑响应…（已等待 ${Math.round(elapsed / 1000)} 秒）`);
        }
        if (elapsed > timeoutMs) {
          FileLog.d(TAG, `waitForReady timeout after ${Math.round(elapsed / 1000)}s: host not reachable`);
          resolve(false);
          return;
        }
        setTimeout(check, 1000);
      };
      // 先给 VPN Extension 1 秒建立虚拟网卡，再开始探测
      setTimeout(check, 1000);
    });
  }
}
