/*
 * 账号专属虚拟网络标识派生
 *
 * 每个账号拥有自己的一套 EasyTier 网络名/密码，相当于每家一个独立小网络：
 *  - 不同账号之间互相看不见，也不会再出现"不同用户分到同一个虚拟 IP"的撞号；
 *  - 同一账号仍共用一个小网段（约 250 个地址），家用/个人几台设备完全够用。
 *
 * 派生算法必须与电脑端 NetworkProvision.cs 完全一致，任何一边改动都要同步。
 */

import { StringUtil } from '../../utils/StringUtil';

export class NetworkIdentity {
  /** 老版本（所有人共用一个公共网络）的网络名，仅用于未登录时兜底 */
  static readonly LEGACY_NAME: string = 'open-remote-2026';

  /** 账号标识 → 网络名，例如 lw-1a2b3c4d5e6f7a8b */
  static deriveName(uid: string): string {
    const base: string = 'lw-net-v1|' + uid;
    return 'lw-' + hex32(hash32(base + '|n1', 5381)) + hex32(hash32(base + '|n2', 52711));
  }

  /** 账号标识 → 网络密码（32 位十六进制） */
  static deriveSecret(uid: string): string {
    const base: string = 'lw-net-v1|' + uid;
    return hex32(hash32(base + '|s1', 33))
      + hex32(hash32(base + '|s2', 131))
      + hex32(hash32(base + '|s3', 17))
      + hex32(hash32(base + '|s4', 29));
  }
}

/** 32 位累加散列：用远小于 2^53 的乘数保证不同语言算出来完全一致 */
function hash32(text: string, seed: number): number {
  const bytes: Uint8Array = StringUtil.stringToUint8Array(text);
  let h: number = seed >>> 0;
  for (let i = 0; i < bytes.length; i++) {
    h = (h * 33 + bytes[i]) >>> 0;
  }
  return h;
}

function hex32(value: number): string {
  return (value >>> 0).toString(16).padStart(8, '0');
}
