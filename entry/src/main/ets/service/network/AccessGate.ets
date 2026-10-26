/*
 * 电脑端控制校验口的客户端。
 *
 * 电脑端托盘在 47999 端口提供三个接口：
 *   GET  /v1/device  设备与账号状态
 *   POST /v1/verify  { accessToken } 同账号校验
 *   POST /v1/code    { code }        临时控制码校验
 *
 * 规则：
 * - 电脑端没有校验口（老版本）→ 放行，避免把用户锁在外面
 * - 电脑端未登录账号 → 放行（尚未启用账号体系）
 * - 电脑端已登录账号且平板同账号 → 放行
 * - 其他情况 → 需要输入控制码
 */

import { HttpClient } from '../../utils/HttpClient';
import { Logger } from '../../common/Logger';
import { LocalIdentity } from './LocalIdentity';
import { PreferencesUtil } from '../../utils/PreferencesUtil';

const TAG: string = 'AccessGate';
const GATE_PORT: number = 47999;
/** 组网固定虚拟 IP，作为备用探测地址 */
const FALLBACK_HOST: string = '10.126.126.1';

interface GateDevice {
  ok?: boolean;
  loggedIn?: boolean;
  deviceId?: string;
  deviceName?: string;
  accountName?: string;
}

interface GateResult {
  ok?: boolean;
  allowed?: boolean;
  reason?: string;
  /** 电脑端代生成的一次性配对码（/v1/pair） */
  pin?: string;
  /** 电脑端下发的组网身份（配对/控制码通过后才有） */
  network?: GateNetwork;
}

interface GateNetwork {
  name?: string;
  secret?: string;
}

export interface AccessDecision {
  /** 允许连接 */
  ok: boolean;
  /** 需要用户输入控制码 */
  needCode: boolean;
  /** 拒绝原因（展示给用户） */
  reason: string;
  /** 实际可达的电脑地址 */
  host: string;
  /** 电脑端设备标识（用于核对是不是同一台电脑） */
  deviceId?: string;
}

export class AccessGate {
  /**
   * 连接前判断这台电脑是否允许当前账号接入。
   * @param host 电脑地址（实测地址或虚拟 IP）
   * @param accessToken 平板当前登录令牌，未登录传空串
   */
  static async check(computerId: string, host: string, accessToken: string): Promise<AccessDecision> {
    const hosts: string[] = [];
    if (host.length > 0) {
      hosts.push(host);
    }
    if (host !== FALLBACK_HOST) {
      hosts.push(FALLBACK_HOST);
    }

    let device: GateDevice | undefined = undefined;
    let reachableHost: string = host;
    for (const candidate of hosts) {
      device = await AccessGate.fetchDevice(candidate);
      if (device !== undefined) {
        reachableHost = candidate;
        break;
      }
    }

    const hostDeviceId: string = device !== undefined && device.deviceId !== undefined ? device.deviceId : '';

    if (device === undefined) {
      // 老版本电脑端没有校验口：直接放行
      return { ok: true, needCode: false, reason: '', host: reachableHost };
    }
    if (device.loggedIn !== true) {
      // 电脑端退出登录后不再默认放行：否则任何人（包括本机号）都能直接连，
      // 等于退出登录没有实际效果。此时走控制码，由电脑端持有人主动授权。
      return {
        ok: false,
        needCode: true,
        reason: '这台电脑当前没有登录账号。请在电脑端登录同一账号，或在电脑端生成控制码后再输入',
        host: reachableHost,
        deviceId: hostDeviceId
      };
    }

    // 平板未登录：不发校验请求，直接走控制码，不在电脑端产生任何打扰
    if (accessToken.length === 0) {
      return {
        ok: false,
        needCode: true,
        reason: '这台电脑已绑定统一账号，请输入控制码，或先用同一账号登录',
        host: reachableHost,
        deviceId: hostDeviceId
      };
    }

    const clientId: string = await LocalIdentity.getClientId();
    const clientName: string = await LocalIdentity.getClientName();
    const body: string = `{"accessToken":${AccessGate.quote(accessToken)},`
      + `"clientId":${AccessGate.quote(clientId)},`
      + `"clientName":${AccessGate.quote(clientName)}}`;
    const result = await AccessGate.postJson(reachableHost, '/v1/verify', body);
    if (result !== undefined && result.allowed === true) {
      return { ok: true, needCode: false, reason: '', host: reachableHost, deviceId: hostDeviceId };
    }
    let reason: string = '账号校验没有通过';
    if (result !== undefined && result.reason !== undefined && result.reason.length > 0) {
      reason = result.reason;
    }
    return {
      ok: false,
      needCode: true,
      reason: reason,
      host: reachableHost,
      deviceId: hostDeviceId
    };
  }

  /**
   * 请求电脑端代为生成一次性配对码：同账号自动配对，用户不需要打开任何网页。
   * @returns 4 位 PIN；失败返回空串
   */
  static async requestPairPin(host: string, accessToken: string, clientName: string): Promise<string> {
    if (accessToken.length === 0) return '';
    const body: string = `{"accessToken":${AccessGate.quote(accessToken)},`
      + `"clientName":${AccessGate.quote(clientName)}}`;
    const result = await AccessGate.postJson(host, '/v1/pair', body);
    if (result !== undefined && result.allowed === true
      && result.pin !== undefined && result.pin.length > 0) {
      await AccessGate.saveNetwork(result.network);
      return result.pin;
    }
    return '';
  }

  /** 提交控制码，返回是否放行 */
  static async verifyCode(host: string, code: string): Promise<AccessDecision> {
    const body: string = `{"code":${AccessGate.quote(code)}}`;
    const result = await AccessGate.postJson(host, '/v1/code', body);
    if (result !== undefined && result.allowed === true) {
      await AccessGate.saveNetwork(result.network);
      return { ok: true, needCode: false, reason: '', host: host };
    }
    let reason: string = '控制码不正确';
    if (result !== undefined && result.reason !== undefined && result.reason.length > 0) {
      reason = result.reason;
    }
    return { ok: false, needCode: true, reason: reason, host: host };
  }

  /**
   * 保存电脑端下发的组网身份。
   * 没登录账号时靠这套值组网（安装包里不再带固定密码）；
   * 已登录账号时仍按账号派生，这里存下来只作兜底，不影响现有逻辑。
   */
  static async saveNetwork(net: GateNetwork | undefined): Promise<void> {
    if (net === undefined || net.name === undefined || net.secret === undefined) return;
    if (net.name.length === 0 || net.secret.length === 0) return;
    try {
      await PreferencesUtil.put('et_network_name', net.name);
      await PreferencesUtil.put('et_network_secret', net.secret);
      Logger.info(TAG, `已保存电脑端下发的组网身份 ${net.name}`);
    } catch (err) {
      Logger.warn(TAG, `保存组网身份失败: ${(err as Error).message}`);
    }
  }

  static async fetchDevice(host: string): Promise<GateDevice | undefined> {
    try {
      const response = await HttpClient.requestRaw(
        `http://${host}:${GATE_PORT}/v1/device`,
        'GET',
        undefined,
        { connectTimeout: 3000, transferTimeout: 3000 }
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return undefined;
      }
      return JSON.parse(response.body as string) as GateDevice;
    } catch (err) {
      Logger.warn(TAG, `探测 ${host} 校验口失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  static async postJson(host: string, path: string, body: string): Promise<GateResult | undefined> {
    try {
      const response = await HttpClient.requestRaw(
        `http://${host}:${GATE_PORT}${path}`,
        'POST',
        body,
        { connectTimeout: 4000, transferTimeout: 4000 }
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return undefined;
      }
      return JSON.parse(response.body as string) as GateResult;
    } catch (err) {
      Logger.warn(TAG, `${path} 请求失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  private static quote(text: string): string {
    let out: string = '';
    for (let i = 0; i < text.length; i++) {
      const c: string = text.charAt(i);
      if (c === '"' || c === '\\') {
        out += '\\' + c;
      } else {
        out += c;
      }
    }
    return `"${out}"`;
  }
}
