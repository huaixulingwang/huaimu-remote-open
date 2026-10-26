/*
 * 本机设备身份（平板端）
 *
 * 第一次启动时生成一个固定的设备标识并持久化，
 * 连接电脑时随账号校验一起发给电脑端，用于「是否允许这台设备连接」的确认与白名单。
 */

import { util } from '@kit.ArkTS';
import { PreferencesUtil } from '../../utils/PreferencesUtil';

const KEY_CLIENT_ID: string = 'local_client_id';

export class LocalIdentity {
  private static cachedId: string = '';

  /** 形如 TB-1A2B3C4D，首次生成后终身不变 */
  static async getClientId(): Promise<string> {
    if (LocalIdentity.cachedId.length > 0) {
      return LocalIdentity.cachedId;
    }
    let id: string = await PreferencesUtil.get<string>(KEY_CLIENT_ID, '');
    if (id.length === 0) {
      const uuid: string = util.generateRandomUUID();
      id = 'TB-' + uuid.substring(0, 8).toUpperCase();
      await PreferencesUtil.put(KEY_CLIENT_ID, id);
    }
    LocalIdentity.cachedId = id;
    return id;
  }

  /** 给电脑端看的设备名，如「平板 3C4D」 */
  static async getClientName(): Promise<string> {
    const id: string = await LocalIdentity.getClientId();
    return `平板 ${id.substring(id.length - 4)}`;
  }
}
