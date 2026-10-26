/*
 * 统一的串流入口。
 *
 * 主页「进入桌面」快捷按钮和应用列表页点击应用都要走这里，
 * 保证两条路径的门禁、显示参数、电脑身份核对完全一致。
 */

import { AppNav } from '../../common/AppNav';
import { AccessCodePageParams, StreamPageParams } from '../../common/PageParams';
import { ComputerManager } from '../ComputerManager';
import { ComputerInfo, selectBestAddress } from '../../model/ComputerInfo';
import { HOST_VIRTUAL_IP } from '../networking/VpnController';
import { AccessGate } from './AccessGate';
import { AccountCenterService } from '../account/AccountCenterService';
import { PreferencesUtil } from '../../utils/PreferencesUtil';
import { SettingsKeys } from '../SettingsService';
import { ToastQueue } from '../../utils/ToastQueue';
import { Logger } from '../../common/Logger';

const TAG: string = 'StreamEntry';

export class StreamEntry {
  /**
   * 进入串流前的唯一出口。
   * 放行 → StreamPage；需要控制码 → AccessCodePage；其他 → 明确提示。
   */
  static async open(computerId: string, params: StreamPageParams): Promise<void> {
    // 隐私屏开关是全局唯一配置：调用方没指定时按全局设置补齐，
    // 否则快捷连接会在隐私屏开启时连到已熄灭的物理屏
    if (params.useVdd === undefined) {
      params.useVdd = await StreamEntry.readPrivacyEnabled();
    }
    if (params.displayGuid === undefined) {
      params.displayGuid = '';
    }

    const info: ComputerInfo | undefined = ComputerManager.getInstance().getComputer(computerId);
    if (info === undefined) {
      ToastQueue.show({ message: '找不到这台电脑的配置' });
      return;
    }

    const best: string = selectBestAddress(info);
    const host: string = best.length > 0 ? best : HOST_VIRTUAL_IP;

    const token: string = await AccountCenterService.getAccessTokenForGate();

    const decision = await AccessGate.check(computerId, host, token);
    Logger.info(TAG,
      `门禁结果: ok=${decision.ok} needCode=${decision.needCode} host=${decision.host} reason=${decision.reason}`);

    if (!(await StreamEntry.verifyHostIdentity(computerId, decision.deviceId))) {
      return;
    }
    if (decision.ok) {
      AppNav.push('StreamPage', params);
      return;
    }
    if (decision.needCode) {
      AppNav.push('AccessCodePage', {
        host: decision.host,
        computerId: computerId,
        computerName: info.name,
        reason: decision.reason,
        stream: params
      } as AccessCodePageParams);
      return;
    }
    ToastQueue.show({ message: decision.reason });
  }

  private static async readPrivacyEnabled(): Promise<boolean> {
    try {
      const value = await PreferencesUtil.get<string | boolean>(SettingsKeys.PRIVACY_SCREEN_ENABLED, false);
      return value === true || value === 'true';
    } catch (err) {
      Logger.warn(TAG, `读取隐私屏设置失败: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * 核对这台电脑是不是上次那台：首次连接记录其设备标识，之后不一致就中止。
   * 防止连到冒用同一虚拟 IP 的其他设备。
   */
  private static async verifyHostIdentity(computerId: string, deviceId?: string): Promise<boolean> {
    if (deviceId === undefined || deviceId.length === 0) {
      return true;
    }
    const key: string = `trusted_device_${computerId}`;
    const known: string = await PreferencesUtil.get<string>(key, '');
    if (known.length > 0 && known !== deviceId) {
      ToastQueue.show({ message: '这台电脑的身份与上次记录不一致，已中止连接' });
      return false;
    }
    if (known.length === 0) {
      await PreferencesUtil.put(key, deviceId);
    }
    return true;
  }
}
