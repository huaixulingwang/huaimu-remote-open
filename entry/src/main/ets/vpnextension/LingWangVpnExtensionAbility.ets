import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import type Want from '@ohos.app.ability.Want';
import { Logger } from '../common/Logger';
import { EasyTierManager } from '../service/networking/EasyTierManager';
import { FileLog } from '../service/networking/FileLog';
import { PreferencesUtil } from '../utils/PreferencesUtil';

const TAG = 'LingWangVpnExt';
const HOST_VIRTUAL_IP = '10.126.126.1';
const SUNSHINE_PORT = 47984;

/**
 * VPN Extension Ability
 *
 * 【P0-1 时序修复】严格按"先启动引擎 → 等引擎就绪 → 再建 TUN → 挂 fd 一次"执行：
 * 引擎 Instance::run() 内部会把网卡换成 mock nic（只吃包不读 TUN），
 * 挂太早真网卡会被顶掉，数据面永久死亡。顺序对了才能拿到可用的网卡。
 */
export default class LingWangVpnExtensionAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null;
  private statusTimer: number = -1;
  // 诊断用：TUN 是否已成功挂到引擎（销毁时把状态记进日志）
  private tunAttached: boolean = false;
  // 黑匣子：主界面卡死是否已上报过（一次冻结只报一次，避免刷屏）
  private uiFrozenReported: boolean = false;

  /** 心跳超过该时长没更新即判定主界面卡死 */
  private static readonly UI_HEARTBEAT_STALE_MS = 20000;

  /**
   * 扩展服务创建时回调。
   * 注意：VpnExtensionAbility 没有 onConnect 回调，虚拟网卡必须在这里创建。
   */
  onCreate(want: Want): void {
    FileLog.init(this.context);
    // VPN 扩展运行在独立进程，主进程的偏好初始化在这里不生效，必须补一次：
    // 否则 EasyTierManager.buildConfig 读节点配置时会抛 "context not initialized"
    PreferencesUtil.init(this.context);
    FileLog.d(TAG, `VPN Extension onCreate, want=${JSON.stringify(want)}`);
    Logger.info(TAG, 'VPN Extension onCreate');
    this.setupVpn().catch((e: Error) => {
      FileLog.d(TAG, `setupVpn error: ${e.message}`);
      Logger.error(TAG, `setupVpn error: ${e.message}`);
    });
  }

  onDestroy(): void {
    // 诊断：区分"系统回收扩展"与"App 主动收摊"。若是 App 主动，同一时刻 VpnController
    // 会先写一行 stopNow/scheduleStop 的 APP-INITIATED 记录，两条对照即可定性。
    FileLog.d(TAG, `VPN Extension onDestroy (tunAttached=${this.tunAttached}, conn=${this.connection ? 'alive' : 'null'})`);
    Logger.info(TAG, 'VPN Extension onDestroy');
    this.cleanup();
  }

  private async setupVpn(): Promise<void> {
    try {
      // ---- 第一步：先启动引擎（还没有 TUN，引擎靠物理网卡连 peer）----
      FileLog.d(TAG, 'step1: startEngine (no tun yet)');
      const started = await EasyTierManager.getInstance().startEngine();
      if (!started) {
        FileLog.d(TAG, 'startEngine failed, abort (no vpn requested)');
        return;
      }

      // ---- 第二步：等引擎就绪（越过 run() 内部的清网卡窗口）----
      FileLog.d(TAG, 'step2: waitEngineReady...');
      await EasyTierManager.getInstance().waitEngineReady();
      FileLog.d(TAG, 'step2 done: engine ready');

      // ---- 第三步：现在才创建 VPN 连接并建 TUN ----
      this.connection = vpnExtension.createVpnConnection(this.context);
      if (!this.connection) {
        FileLog.d(TAG, 'createVpnConnection returned null');
        Logger.error(TAG, 'createVpnConnection returned null');
        return;
      }

      // TUN 接口地址必须与引擎虚拟 IP 完全一致，否则回程是黑洞
      const ip = EasyTierManager.getInstance().getVirtualIpv4();
      FileLog.d(TAG, `step3: create tun, address=${ip}`);
      Logger.info(TAG, `create tun, address=${ip}`);

      const config: vpnExtension.VpnConfig = {
        addresses: [
          { address: { address: ip }, prefixLength: 24 }
        ],
        routes: [
          {
            interface: '',
            destination: { address: { address: '10.126.126.0' }, prefixLength: 24 },
            gateway: { address: '' },
            hasGateway: false,
            isDefaultRoute: false
          }
        ],
        // 必须与 EasyTier 虚拟网络自身的 MTU 对齐（引擎侧默认 1380）。
        // 网卡给 1500 会让系统把超过隧道承载能力的大包塞进引擎，大包被吞后表现为
        // "小包探测全绿、视频流却先冻住"，所以这里不能用系统默认的 1500。
        mtu: 1380,
        // 与 15:30 成功轮一致的非阻塞模式
        isBlocking: false
      };

      // 系统同时只允许一个 VPN：通道被别的工具（如外部 EasyTier）占着时会报 2203002。
      // 这种情况短等几秒再试（对方可能正在拆除），仍不行就如实报错，不假装成功。
      let tunFd: number = -1;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          tunFd = await this.connection.create(config);
          break;
        } catch (err) {
          const msg = JSON.stringify(err);
          FileLog.d(TAG, `TUN create attempt ${attempt}/3 failed: ${msg}`);
          const busy = msg.indexOf('2203002') >= 0;
          if (!busy || attempt === 3) {
            throw err as Error;
          }
          await new Promise<void>((resolve: () => void) => {
            setTimeout(resolve, 1500);
          });
        }
      }
      FileLog.d(TAG, `TUN fd created: ${tunFd}`);
      if (tunFd <= 0) {
        FileLog.d(TAG, 'TUN fd invalid, destroy connection');
        Logger.error(TAG, 'TUN fd invalid');
        await this.safeDestroy();
        await EasyTierManager.getInstance().stop();
        return;
      }

      // ---- 第四步：挂 fd（只挂一次）----
      const attached = await EasyTierManager.getInstance().attachTunFd(tunFd);
      if (!attached) {
        // 挂载失败必须立刻释放 TUN，否则空白虚拟网卡会占着系统 VPN，
        // 顶掉其他 VPN 应用并造成 10.126.126.0/24 路由黑洞
        FileLog.d(TAG, 'attachTunFd failed, destroy TUN + stop engine');
        Logger.error(TAG, 'attachTunFd failed');
        await this.safeDestroy();
        await EasyTierManager.getInstance().stop();
        return;
      }

      this.tunAttached = true;
      FileLog.d(TAG, 'tun attached OK, build done');
      this.startStatusReport();
    } catch (e) {
      FileLog.d(TAG, `setupVpn catch: ${JSON.stringify(e)}`);
      Logger.error(TAG, `setupVpn catch: ${JSON.stringify(e)}`);
    }
  }

  onDisconnect(): void {
    // 系统侧撤销 VPN 通道时才会走到这里，与 App 主动收摊是两条完全不同的路径
    FileLog.d(TAG, 'VPN Extension onDisconnect (system revoked vpn)');
    Logger.info(TAG, 'VPN onDisconnect');
    this.cleanup();
  }

  /**
   * 每 10 秒把引擎视角的网络状态写进持久化日志，并从扩展进程内探测电脑端口。
   * 用于核验"真网卡进入工作状态"（netinfos 里 peers/路由会变化）+ 数据面连通性。
   */
  private startStatusReport(): void {
    this.stopStatusReport();
    let tick = 0;
    EasyTierManager.getInstance().dumpNetworkInfosToLog('boot');
    this.probeFromExtProcess('boot');
    this.statusTimer = setInterval(() => {
      tick += 1;
      EasyTierManager.getInstance().dumpNetworkInfosToLog(`t+${tick * 10}s`);
      this.probeFromExtProcess(`t+${tick * 10}s`);
      this.checkUiHeartbeat();
    }, 10000);
  }

  /**
   * 黑匣子：本扩展跑在与 App 主界面不同的线程上，主界面卡死时这里仍然在跑，
   * 所以由它判定"主界面卡死"最可靠。心跳文件超过 20 秒没更新即判定卡死，
   * 当场把现场写进日志并落下标记，供下次启动时提示用户。
   */
  private checkUiHeartbeat(): void {
    const ageMs = FileLog.readHeartbeatAgeMs();
    if (ageMs < 0) {
      // 没有心跳文件：当前不在串流页面，属正常情况
      return;
    }
    if (ageMs <= LingWangVpnExtensionAbility.UI_HEARTBEAT_STALE_MS) {
      this.uiFrozenReported = false;
      return;
    }
    if (this.uiFrozenReported) {
      return;
    }
    this.uiFrozenReported = true;
    const detail = `App 主界面无响应，心跳已停 ${Math.round(ageMs / 1000)}s`;
    FileLog.d(TAG, `UI-FROZEN: ${detail}`);
    FileLog.writeFreezeFlag(detail);
  }

  private probeFromExtProcess(label: string): void {
    const tcp = socket.constructTCPSocketInstance();
    let settled = false;
    const t0 = Date.now();
    const finish = (ok: boolean, detail: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        tcp.close();
      } catch (_) {
      }
      FileLog.d(TAG, `ext-probe[${label}] ${ok ? 'REACHABLE' : 'fail'} ${Date.now() - t0}ms ${detail}`);
    };
    tcp.connect({ address: { address: HOST_VIRTUAL_IP, port: SUNSHINE_PORT }, timeout: 3000 })
      .then(() => finish(true, ''))
      .catch((e: Error) => finish(false, e.message));
  }

  private stopStatusReport(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private async safeDestroy(): Promise<void> {
    if (!this.connection) {
      return;
    }
    try {
      await this.connection.destroy();
    } catch (e) {
      FileLog.d(TAG, `destroy error: ${JSON.stringify(e)}`);
    }
    this.connection = null;
  }

  private cleanup(): void {
    this.stopStatusReport();
    EasyTierManager.getInstance().stop();
    if (this.connection) {
      try {
        this.connection.destroy();
      } catch (e) {
        Logger.warn(TAG, `destroy connection error: ${JSON.stringify(e)}`);
      }
      this.connection = null;
    }
  }
}
