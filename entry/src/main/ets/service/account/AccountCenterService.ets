/*
 * 统一账号中心（CloudBase）接入
 *
 * 接口依据：account-center/接入说明.md 第 3 节（原生 HTTP，已实测）
 * - 原生请求不带来源头，不受第三方跨域限制，故不使用 WebView / JS SDK
 * - 客户端不需要任何密钥，只要环境 ID；access_token 有效期 2 小时
 * - refresh_token 只存系统安全存储（Asset Store Kit），不写日志
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { HttpClient, HttpClientConfig, HttpMethod } from '../../utils/HttpClient';
import { PreferencesUtil } from '../../utils/PreferencesUtil';
import { Logger } from '../../common/Logger';
import { LocalIdentity } from '../network/LocalIdentity';

/** 环境 ID（同时也是 client_id） */
const ENV_ID: string = 'your-env-id';
/** 认证与管理 API 根地址 */
const API_BASE: string = 'https://your-env-id.api.tcloudbasegateway.com';
/** PG REST 根地址 */
const REST_BASE: string = 'https://your-env-id.api.tcloudbasegateway.com/v1/rdb/rest';
/** 本产品在账号中心的代码 */
const PRODUCT_CODE: string = 'remote-control';

const TAG: string = 'AccountCenter';

/** 安全存储里的键名 */
const ACCESS_TOKEN_ALIAS: string = 'lingwang_account_access_token';
const REFRESH_TOKEN_ALIAS: string = 'lingwang_account_refresh_token';

/** 本地偏好键（只存非敏感信息） */
const KEY_ACCOUNT_ID: string = 'account_id';
const KEY_DISPLAY_NAME: string = 'account_display_name';
const KEY_AVATAR_URL: string = 'account_avatar_url';
const KEY_EXPIRES_AT: string = 'account_expires_at';
const KEY_AUTHORIZED: string = 'account_product_authorized';
const KEY_LAST_CHECK: string = 'account_last_check_at';

/** 登录成功返回 */
export interface AccountSession {
  token_type: string;
  access_token: string;
  refresh_token: string;
  expires_in: number;
  sub: string;
}

/** 发码返回 */
export interface VerificationResult {
  verification_id: string;
  is_user: boolean;
}

/** 校验验证码返回 */
export interface VerifyResult {
  verification_token: string;
}

/** 账号设备名单里的一条记录 */
export interface AccountDevice {
  id?: string;
  device_id: string;
  device_name: string;
  device_type: string;
  sunshine_id?: string;
  virtual_ip?: string;
  last_seen_at?: string;
}

/** 写入设备表时的字段集（ArkTS 不允许未类型化的对象字面量） */
interface DeviceRow {
  owner_id: string;
  device_id: string;
  device_name: string;
  device_type: string;
  product_code: string;
  sunshine_id: string;
  virtual_ip: string;
  last_seen_at: string;
}

/** 当前账号状态 */
export interface AccountMe {
  sub: string;
  username: string;
  name: string;
  email: string;
  status: string;
}

/** 资料行 */
interface ProfileRow {
  id: string;
  username?: string;
  display_name?: string;
  avatar_url?: string;
}

/** 授权行 */
interface MemberRow {
  product_id?: string;
  role?: string;
  products?: ProductRow | ProductRow[];
}

interface ProductRow {
  code?: string;
  name?: string;
}

/** 请求体 */
interface PhoneBody {
  phone_number: string;
}

interface VerifyBody {
  verification_id: string;
  verification_code: string;
}

interface SignInCodeBody {
  username: string;
  verification_token: string;
}

interface SignUpBody {
  phone_number: string;
  verification_code: string;
  verification_token: string;
  name: string;
}

interface PasswordBody {
  username: string;
  password: string;
}

interface RefreshBody {
  grant_type: string;
  refresh_token: string;
}

/** 账号中心错误响应 */
interface ApiErrorBody {
  code?: string;
  error?: string;
  error_description?: string;
  error_code?: string | number;
}

/** 账号中心接口错误（message 可直接展示给用户） */
export class AccountCenterError extends Error {
  readonly statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.name = 'AccountCenterError';
    this.statusCode = statusCode;
  }
}

/** 本地登录态快照 */
export interface AccountSnapshot {
  loggedIn: boolean;
  accountId: string;
  displayName: string;
  avatarUrl: string;
  authorized: boolean;
}

// ---------------------------------------------------------------------------
// 安全存储：refresh_token / access_token 走 Asset Store，Preferences 只放元数据
// ---------------------------------------------------------------------------

function encodeText(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

function decodeText(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

// Asset Store 的 SECRET 单条上限 1024 字节，而 JWT 访问令牌常超过这个长度，
// 所以按 900 字节分片存储，读取时按顺序拼回。别名格式：<alias>#0、<alias>#1 ...
const SECRET_CHUNK_SIZE = 900;
const MAX_SECRET_CHUNKS = 16;

function chunkAlias(alias: string, index: number): string {
  return `${alias}#${index}`;
}

async function secureGetRawBytes(alias: string): Promise<Uint8Array | undefined> {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, encodeText(alias));
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  try {
    const rows = await asset.query(query);
    if (rows.length === 0) {
      return undefined;
    }
    const value = rows[0].get(asset.Tag.SECRET);
    if (value instanceof Uint8Array) {
      return value;
    }
    return undefined;
  } catch (err) {
    return undefined;
  }
}

async function securePut(alias: string, secret: string): Promise<void> {
  await secureRemove(alias);
  const bytes = encodeText(secret);
  const chunkCount = Math.max(1, Math.ceil(bytes.length / SECRET_CHUNK_SIZE));
  for (let i = 0; i < chunkCount; i++) {
    const start = i * SECRET_CHUNK_SIZE;
    const end = Math.min(start + SECRET_CHUNK_SIZE, bytes.length);
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, encodeText(chunkAlias(alias, i)));
    attrs.set(asset.Tag.SECRET, bytes.slice(start, end));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    await asset.add(attrs);
  }
}

async function secureGet(alias: string): Promise<string> {
  const parts: Uint8Array[] = [];
  let total = 0;
  for (let i = 0; i < MAX_SECRET_CHUNKS; i++) {
    const part = await secureGetRawBytes(chunkAlias(alias, i));
    if (part === undefined || part.length === 0) {
      break;
    }
    parts.push(part);
    total += part.length;
  }
  if (parts.length === 0) {
    // 兼容早期未分片的单条存储
    const legacy = await secureGetRawBytes(alias);
    return legacy === undefined ? '' : decodeText(legacy);
  }
  // 先拼字节再解码，避免 UTF-8 字符被分片切断
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    merged.set(part, offset);
    offset += part.length;
  }
  return decodeText(merged);
}

async function secureRemove(alias: string): Promise<void> {
  for (let i = 0; i < MAX_SECRET_CHUNKS; i++) {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encodeText(chunkAlias(alias, i)));
    try {
      await asset.remove(query);
    } catch (err) {
      // 不存在时忽略
    }
  }
  const legacy: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  legacy.set(asset.Tag.ALIAS, encodeText(alias));
  try {
    await asset.remove(legacy);
  } catch (err) {
    // 不存在时忽略
  }
}

// ---------------------------------------------------------------------------

export class AccountCenterService {
  /** 正在进行的续期请求：并发调用共享同一个 Promise，避免 refresh_token 被轮换两次 */
  private static refreshInFlight: Promise<AccountSession> | null = null;

  /**
   * 把用户输入的手机号整理成账号中心要求的格式：+86 13800138000
   * 去空格和短横线；以 86 开头的 13 位去掉 86；其余 11 位手机号补 +86。
   */
  static normalizePhone(input: string): string {
    let s = input.trim().replace(/\s+/g, '').replace(/-/g, '');
    if (s.startsWith('+86')) {
      s = s.substring(3);
    } else if (s.startsWith('86') && s.length === 13) {
      s = s.substring(2);
    } else if (s.startsWith('+')) {
      return input.trim();
    }
    if (s.length === 11 && s.startsWith('1')) {
      return `+86 ${s}`;
    }
    return s;
  }

  /** 1. 发送验证码，返回该手机号是否已注册 */
  static async sendVerificationCode(phone: string): Promise<VerificationResult> {
    const payload: PhoneBody = { phone_number: phone };
    const body = JSON.stringify(payload);
    const text = await AccountCenterService.request('POST', `/auth/v1/verification?client_id=${ENV_ID}`, body);
    const data = JSON.parse(text) as VerificationResult;
    Logger.info(TAG, `验证码已发送，已注册=${data.is_user}`);
    return data;
  }

  /** 2. 校验验证码，拿到 verification_token */
  static async verifyCode(verificationId: string, code: string): Promise<string> {
    const payload: VerifyBody = {
      verification_id: verificationId,
      verification_code: code
    };
    const body = JSON.stringify(payload);
    const text = await AccountCenterService.request('POST', `/auth/v1/verification/verify?client_id=${ENV_ID}`, body);
    const data = JSON.parse(text) as VerifyResult;
    return data.verification_token;
  }

  /** 3a. 老用户用验证码登录 */
  static async signInWithCode(phone: string, verificationToken: string): Promise<AccountSession> {
    const payload: SignInCodeBody = {
      username: phone,
      verification_token: verificationToken
    };
    const body = JSON.stringify(payload);
    const text = await AccountCenterService.request('POST', `/auth/v1/signin?client_id=${ENV_ID}`, body);
    return await AccountCenterService.saveSession(JSON.parse(text) as AccountSession);
  }

  /** 3b. 新用户注册（注册即登录） */
  static async signUpWithCode(phone: string, code: string, verificationToken: string, name: string): Promise<AccountSession> {
    const payload: SignUpBody = {
      phone_number: phone,
      verification_code: code,
      verification_token: verificationToken,
      name: name
    };
    const body = JSON.stringify(payload);
    const text = await AccountCenterService.request('POST', `/auth/v1/signup?client_id=${ENV_ID}`, body);
    return await AccountCenterService.saveSession(JSON.parse(text) as AccountSession);
  }

  /** 3c. 账号密码登录 */
  static async signInWithPassword(username: string, password: string): Promise<AccountSession> {
    // 密码登录时，11 位手机号必须先规范成 "+86 137xxxxxxxx"，否则账号中心返回 4043
    const loginName = AccountCenterService.normalizePhone(username);
    const payload: PasswordBody = { username: loginName, password: password };
    const body = JSON.stringify(payload);
    const text = await AccountCenterService.request('POST', `/auth/v1/signin?client_id=${ENV_ID}`, body);
    return await AccountCenterService.saveSession(JSON.parse(text) as AccountSession);
  }

  /** 4. 用 refresh_token 续期（同一时刻只允许一次，避免凭证被并发轮换掉） */
  static async refreshSession(): Promise<AccountSession> {
    if (AccountCenterService.refreshInFlight !== null) {
      return AccountCenterService.refreshInFlight;
    }
    const task = AccountCenterService.doRefreshSession();
    AccountCenterService.refreshInFlight = task;
    try {
      return await task;
    } finally {
      AccountCenterService.refreshInFlight = null;
    }
  }

  private static async doRefreshSession(): Promise<AccountSession> {
    const refreshToken = await secureGet(REFRESH_TOKEN_ALIAS);
    if (refreshToken.length === 0) {
      throw new AccountCenterError(401, '登录已失效，请重新登录');
    }
    const payload: RefreshBody = {
      grant_type: 'refresh_token',
      refresh_token: refreshToken
    };
    const body = JSON.stringify(payload);
    try {
      const text = await AccountCenterService.request('POST', `/auth/v1/token?client_id=${ENV_ID}`, body);
      const session = JSON.parse(text) as AccountSession;
      Logger.info(TAG, '登录凭证已续期');
      return await AccountCenterService.saveSession(session);
    } catch (err) {
      // 只有服务端明确说凭证失效才清登录态；网络波动不能把用户踢下线
      const message: string = (err as Error).message.toLowerCase();
      if (message.includes('invalid refresh token') || message.includes('登录已失效')) {
        await AccountCenterService.logout();
      }
      throw err as Error;
    }
  }

  /** 取有效 access_token：快过期（不足 5 分钟）先续期 */
  static async getAccessToken(): Promise<string> {
    const token = await secureGet(ACCESS_TOKEN_ALIAS);
    if (token.length === 0) {
      throw new AccountCenterError(401, '尚未登录');
    }
    const expiresAt = await PreferencesUtil.get<number>(KEY_EXPIRES_AT, 0);
    const now = Date.now();
    if (expiresAt > 0 && now < expiresAt - 5 * 60 * 1000) {
      return token;
    }
    const session = await AccountCenterService.refreshSession();
    return session.access_token;
  }

  /**
   * 门禁用：取当前 access_token。
   * 与 getAccessToken 的区别是网络不好（例如组网后 DNS 暂时不可用）时
   * 不抛错、也不清本地登录态，直接回退旧令牌；是否过期交给电脑端判断。
   */
  static async getAccessTokenForGate(): Promise<string> {
    let token: string = '';
    try {
      token = await secureGet(ACCESS_TOKEN_ALIAS);
    } catch (err) {
      token = '';
    }
    if (token.length === 0) {
      return '';
    }
    try {
      const expiresAt = await PreferencesUtil.get<number>(KEY_EXPIRES_AT, 0);
      if (expiresAt > 0 && Date.now() < expiresAt - 5 * 60 * 1000) {
        return token;
      }
      const refreshToken = await secureGet(REFRESH_TOKEN_ALIAS);
      if (refreshToken.length === 0) {
        return token;
      }
      const payload: RefreshBody = {
        grant_type: 'refresh_token',
        refresh_token: refreshToken
      };
      const text = await AccountCenterService.request(
        'POST', `/auth/v1/token?client_id=${ENV_ID}`, JSON.stringify(payload));
      const session = JSON.parse(text) as AccountSession;
      const saved = await AccountCenterService.saveSession(session);
      Logger.info(TAG, '登录凭证已续期（门禁路径）');
      return saved.access_token;
    } catch (err) {
      Logger.warn(TAG, `门禁取令牌时续期失败，回退旧令牌: ${(err as Error).message}`);
      return token;
    }
  }

  /**
   * 组网后探测账号中心是否可达（只用于日志诊断，不影响连接）。
   * 组网后若系统 DNS 被顶掉，这里会明确留下一条 warn，便于定位门禁取令牌失败。
   */
  static async probeReachable(): Promise<boolean> {
    try {
      const res = await HttpClient.requestRaw(
        `${API_BASE}/auth/v1/certs`,
        'GET',
        undefined,
        { connectTimeout: 4000, transferTimeout: 4000 }
      );
      const ok: boolean = res.statusCode >= 200 && res.statusCode < 300;
      if (ok) {
        Logger.info(TAG, `账号中心探测成功: ${res.statusCode}`);
      } else {
        Logger.warn(TAG, `账号中心探测异常: ${res.statusCode}`);
      }
      return ok;
    } catch (err) {
      Logger.warn(TAG, `账号中心探测失败（组网后 DNS/网络可能不可用）: ${(err as Error).message}`);
      return false;
    }
  }

  // ── 设备名单 ─────────────────────────────────────

  /**
   * 把本机登记到账号的设备名单。登录成功后和 App 启动时调用，
   * 失败只记日志，不影响本地连接功能。
   */
  static async registerThisDevice(): Promise<void> {
    try {
      const token = await AccountCenterService.getAccessTokenForGate();
      if (token.length === 0) {
        return;
      }
      const ownerId = await PreferencesUtil.get<string>(KEY_ACCOUNT_ID, '');
      if (ownerId.length === 0) {
        return;
      }
      const deviceId = await LocalIdentity.getClientId();
      const deviceName = await LocalIdentity.getClientName();

      // 按 (owner_id, device_id) 幂等写入：先删后插，避免重复行
      await AccountCenterService.request(
        'DELETE',
        `${REST_BASE}/devices?owner_id=eq.${ownerId}&device_id=eq.${deviceId}`,
        undefined,
        token
      );
      const row: DeviceRow = {
        owner_id: ownerId,
        device_id: deviceId,
        device_name: deviceName,
        device_type: 'tablet',
        product_code: PRODUCT_CODE,
        sunshine_id: '',
        virtual_ip: '',
        last_seen_at: new Date().toISOString()
      };
      await AccountCenterService.request('POST', `${REST_BASE}/devices`, JSON.stringify(row), token);
      Logger.info(TAG, `本机已登记到账号设备名单: ${deviceId}`);
    } catch (err) {
      Logger.warn(TAG, `登记设备失败: ${(err as Error).message}`);
    }
  }

  /** 拉取账号下的设备名单（平板、电脑都会包含） */
  static async fetchDevices(): Promise<AccountDevice[]> {
    const token = await AccountCenterService.getAccessToken();
    const text = await AccountCenterService.request(
      'GET',
      `${REST_BASE}/devices?select=id,device_id,device_name,device_type,sunshine_id,virtual_ip,last_seen_at&order=last_seen_at.desc`,
      undefined,
      token
    );
    return JSON.parse(text) as AccountDevice[];
  }

  /** 从账号里删除一台设备（只删名单记录，不影响该设备本机登录） */
  static async deleteDevice(deviceId: string): Promise<void> {
    const token = await AccountCenterService.getAccessToken();
    const ownerId = await PreferencesUtil.get<string>(KEY_ACCOUNT_ID, '');
    await AccountCenterService.request(
      'DELETE',
      `${REST_BASE}/devices?owner_id=eq.${ownerId}&device_id=eq.${deviceId}`,
      undefined,
      token
    );
  }

  /** 5. 查询当前账号（含冻结状态） */
  static async fetchMe(): Promise<AccountMe> {
    const token = await AccountCenterService.getAccessToken();
    const text = await AccountCenterService.request('GET', '/auth/v1/user/me', undefined, token);
    return JSON.parse(text) as AccountMe;
  }

  /** 6. 读取资料（昵称、头像），并写回本地 */
  static async fetchProfile(): Promise<void> {
    const token = await AccountCenterService.getAccessToken();
    const text = await AccountCenterService.request(
      'GET',
      `${REST_BASE}/profiles?select=id,username,display_name,avatar_url`,
      undefined,
      token
    );
    const rows = JSON.parse(text) as ProfileRow[];
    if (rows.length > 0) {
      const row = rows[0];
      if (row.display_name !== undefined && row.display_name.length > 0) {
        await PreferencesUtil.put(KEY_DISPLAY_NAME, row.display_name);
      }
      if (row.avatar_url !== undefined) {
        await PreferencesUtil.put(KEY_AVATAR_URL, row.avatar_url);
      }
    }
  }

  /**
   * 7. 查询本产品是否已开通
   * 按账号中心 3.8 新版：select 必须带 products(id,code,name)，
   * 返回的 products 是对象（不是数组），授权判断看 products.code。
   */
  static async fetchAuthorization(): Promise<boolean> {
    const token = await AccountCenterService.getAccessToken();
    const text = await AccountCenterService.request(
      'GET',
      `${REST_BASE}/product_members?select=product_id,role,products(id,code,name)`,
      undefined,
      token
    );
    const rows = JSON.parse(text) as MemberRow[];
    let authorized = false;
    for (const row of rows) {
      const product = row.products;
      if (product !== undefined && !Array.isArray(product)) {
        if ((product as ProductRow).code === PRODUCT_CODE) {
          authorized = true;
          break;
        }
      }
    }
    await PreferencesUtil.put(KEY_AUTHORIZED, authorized);
    await PreferencesUtil.put(KEY_LAST_CHECK, Date.now());
    return authorized;
  }

  /** 登录后拉一次账号资料与授权，失败不影响登录本身 */
  static async syncAccountInfo(): Promise<void> {
    try {
      await AccountCenterService.fetchMe();
    } catch (err) {
      Logger.warn(TAG, `读取账号状态失败: ${(err as Error).message}`);
    }
    try {
      await AccountCenterService.fetchProfile();
    } catch (err) {
      Logger.warn(TAG, `读取账号资料失败: ${(err as Error).message}`);
    }
    try {
      await AccountCenterService.fetchAuthorization();
    } catch (err) {
      Logger.warn(TAG, `读取产品授权失败: ${(err as Error).message}`);
    }
  }

  /** 校验登录态：token 可用且账号状态正常才算有效 */
  static async validateSession(): Promise<boolean> {
    const token = await secureGet(ACCESS_TOKEN_ALIAS);
    if (token.length === 0) {
      return false;
    }
    try {
      const me = await AccountCenterService.fetchMe();
      return me.status === 'ACTIVE';
    } catch (err) {
      return false;
    }
  }

  /** 本地登录态快照（不发网络请求） */
  static async getSnapshot(): Promise<AccountSnapshot> {
    const accessToken = await secureGet(ACCESS_TOKEN_ALIAS);
    const accountId = await PreferencesUtil.get<string>(KEY_ACCOUNT_ID, '');
    return {
      loggedIn: accessToken.length > 0 && accountId.length > 0,
      accountId: accountId,
      displayName: await PreferencesUtil.get<string>(KEY_DISPLAY_NAME, ''),
      avatarUrl: await PreferencesUtil.get<string>(KEY_AVATAR_URL, ''),
      authorized: await PreferencesUtil.get<boolean>(KEY_AUTHORIZED, false)
    };
  }

  /** 退出登录：清本地凭证 */
  static async logout(): Promise<void> {
    await secureRemove(ACCESS_TOKEN_ALIAS);
    await secureRemove(REFRESH_TOKEN_ALIAS);
    await PreferencesUtil.put(KEY_ACCOUNT_ID, '');
    await PreferencesUtil.put(KEY_DISPLAY_NAME, '');
    await PreferencesUtil.put(KEY_AVATAR_URL, '');
    await PreferencesUtil.put(KEY_EXPIRES_AT, 0);
    await PreferencesUtil.put(KEY_AUTHORIZED, false);
    await PreferencesUtil.put(KEY_LAST_CHECK, 0);
  }

  // -------------------------------------------------------------------------

  private static async saveSession(session: AccountSession): Promise<AccountSession> {
    await securePut(ACCESS_TOKEN_ALIAS, session.access_token);
    await securePut(REFRESH_TOKEN_ALIAS, session.refresh_token);
    await PreferencesUtil.put(KEY_ACCOUNT_ID, session.sub);
    await PreferencesUtil.put(KEY_EXPIRES_AT, Date.now() + session.expires_in * 1000);
    return session;
  }

  /** 统一的 HTTP 请求：原生请求，明确启用系统证书校验 */
  private static async request(
    method: HttpMethod,
    path: string,
    body?: string,
    accessToken?: string
  ): Promise<string> {
    const headers: Record<string, string> = {};
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
    }
    if (accessToken !== undefined && accessToken.length > 0) {
      headers['Authorization'] = `Bearer ${accessToken}`;
    }
    const config: HttpClientConfig = {
      headers: headers,
      connectTimeout: 10000,
      transferTimeout: 15000,
      skipServerValidation: false
    };
    let statusCode: number = 0;
    let responseBody: string = '';
    try {
      // 有些调用方直接传完整地址（REST_BASE 开头的数据库接口），不能再拼一次 API_BASE
      const url: string = path.startsWith('http') ? path : `${API_BASE}${path}`;
      const response = await HttpClient.requestRaw(url, method, body, config);
      statusCode = response.statusCode;
      responseBody = response.body === null || response.body === undefined ? '' : response.body;
    } catch (err) {
      Logger.warn(TAG, `账号请求失败: ${(err as Error).message}`);
      throw new AccountCenterError(-1, '网络连接失败，请检查网络后重试');
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw new AccountCenterError(
        statusCode,
        AccountCenterService.extractErrorMessage(responseBody, statusCode)
      );
    }
    if (responseBody.length === 0) {
      // 删除成功返回 204；写入成功（未要求返回内容）返回 201 空体，都是正常结果
      if (method === 'DELETE' || method === 'POST') {
        return '';
      }
      throw new AccountCenterError(statusCode, '账号服务返回为空');
    }
    return responseBody;
  }

  private static extractErrorMessage(body: string, statusCode: number): string {
    try {
      const data = JSON.parse(body) as ApiErrorBody;
      if (data.error_code !== undefined) {
        const errorCode = `${data.error_code}`;
        if (errorCode === '4043') {
          return '账号或密码不正确';
        }
        if (errorCode === '4029') {
          return '这个账号还没有设置密码，请先用手机号验证码登录，再到账号中心设置密码';
        }
        if (errorCode === '4018' || errorCode === '4041' || errorCode === '4028') {
          return '验证码不正确或已过期，请重新获取';
        }
        if (errorCode === '429' || errorCode === '4042') {
          return '操作太频繁，请稍后再试';
        }
      }
      if (statusCode === 429) {
        return '操作太频繁，请稍后再试';
      }
      if (data.error_description !== undefined && data.error_description.length > 0) {
        return data.error_description;
      }
      if (data.error !== undefined && data.error.length > 0) {
        return data.error;
      }
    } catch (err) {
      // 非 JSON 错误体，落到默认文案
    }
    if (statusCode === 401) {
      return '登录已失效，请重新登录';
    }
    return `账号服务返回 ${statusCode}`;
  }
}
