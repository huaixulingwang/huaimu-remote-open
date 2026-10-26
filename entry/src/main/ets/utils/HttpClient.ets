/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import { http } from '@kit.NetworkKit';
import { Logger } from '../common/Logger';

/**
 * 与 @ohos.net.http 错误对象结构对齐的最小接口
 * （避免为类型断言引入 @ohos.base 依赖）
 */
interface HttpErrorLike {
  code?: number;
  message?: string;
}

/** 取消错误：name='CanceledError'，与 NvHttp.CanceledError 结构对齐 */
interface CancelableError extends Error {
  isCanceled: boolean;
}

/**
 * HTTP 客户端配置
 */
export interface HttpClientConfig {
  /** 连接超时（毫秒） */
  connectTimeout?: number;
  /** 传输超时（毫秒） */
  transferTimeout?: number;
  /** 自定义请求头 */
  headers?: Record<string, string>;
  /** 是否跳过服务器证书验证 */
  skipServerValidation?: boolean;
  /** 客户端证书文件路径（PEM 格式） */
  clientCertPath?: string;
  /** 客户端私钥文件路径（PEM 格式） */
  clientKeyPath?: string;
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH' | 'HEAD';

/**
 * HTTP 响应
 */
export interface HttpResponse {
  statusCode: number;
  body: string;
}

/**
 * 独立 HTTP 会话参数
 *
 * 注：@ohos.net.http 的连接池由系统 netstack 统一管理，无需应用层
 * 再做 session 缓存（原 rcp Session 池已随库切换移除）。
 * 本接口保留原有的证书/验证语义字段。
 */
export interface HttpSessionOptions {
  /** 是否跳过服务器证书验证（私有 PC/Sunshine 自签证书需开启） */
  skipServerValidation: boolean;
  /** 客户端 PEM 证书路径（已配对的 PC 必填） */
  clientCertPath?: string;
  /** 客户端 PEM 私钥路径 */
  clientKeyPath?: string;
}

/**
 * 请求执行器的原始返回：状态码 + 未二次加工的响应体
 */
interface RawResponse {
  statusCode: number;
  raw: string | ArrayBuffer;
}

/**
 * 独占的二进制 HTTP 会话，适用于需要精确取消边界的短生命周期任务。
 */
export class BinaryHttpSession {
  private readonly options: HttpSessionOptions;
  private current: http.HttpRequest | null = null;
  private closed = false;

  constructor(options: HttpSessionOptions) {
    this.options = options;
  }

  async get(url: string, config?: HttpClientConfig): Promise<ArrayBuffer> {
    if (this.closed) {
      throw HttpClient.makeCanceledError();
    }

    const request = http.createHttp();
    this.current = request;
    try {
      const sessionOptions: HttpSessionOptions = {
        skipServerValidation: this.options.skipServerValidation,
        clientCertPath: this.options.clientCertPath,
        clientKeyPath: this.options.clientKeyPath
      };
      const options = HttpClient.buildRequestOptions('GET', config, undefined, sessionOptions, true);
      const response = await request.request(url, options);
      if (response.responseCode !== 200) {
        throw new Error('HTTP ' + response.responseCode.toString());
      }
      const body = response.result as ArrayBuffer;
      if (!body || body.byteLength === 0) {
        throw new Error('响应体为空');
      }
      return body;
    } catch (err) {
      if (this.closed) {
        // close() 触发的在途取消必须呈现为取消错误，供上层与真实网络错误区分
        throw HttpClient.makeCanceledError();
      }
      throw new Error(`HTTP 请求失败: ${HttpClient.describeError(err)}`);
    } finally {
      this.current = null;
      HttpClient.destroyQuietly(request);
    }
  }

  close(): void {
    this.closed = true;
    const request = this.current;
    if (request) {
      HttpClient.destroyQuietly(request);
    }
  }
}

/**
 * HTTP 客户端工具类
 *
 * 统一处理 HTTP/HTTPS 请求，基于系统网络库 @ohos.net.http。
 *
 * 为什么从 rcp (RemoteCommunicationKit) 切换：
 * 部分设备系统镜像未内置 rcp 原生库（librcp_napi.z.so 缺失，
 * 三个模块名 @ohos.net.rcp / @hms.collaboration.rcp / @kit.RemoteCommunicationKit
 * 全部无法加载），而 @ohos.net.http 是鸿蒙基础网络库，全设备可用。
 * TLS 能力一比一等价：remoteValidation:'skip' ↔ 自签证书、clientCert ↔ mTLS。
 */
export class HttpClient {
  /** 默认连接超时 */
  static readonly DEFAULT_CONNECT_TIMEOUT = 5000;
  /** 默认传输超时 */
  static readonly DEFAULT_TRANSFER_TIMEOUT = 7000;
  /** 长连接超时（用于等待用户操作的请求） */
  static readonly LONG_TRANSFER_TIMEOUT = 300000;

  /** 二进制响应上限（带宽探测需要大响应体；http 默认仅 5MB） */
  private static readonly MAX_BINARY_BYTES = 100 * 1024 * 1024;

  /**
   * 构造请求级 HttpRequestOptions（BinaryHttpSession 与 HttpClient 共用）
   */
  static buildRequestOptions(
    method: HttpMethod,
    config: HttpClientConfig | undefined,
    body: string | ArrayBuffer | undefined,
    sessionOptions: HttpSessionOptions,
    binaryResponse: boolean
  ): http.HttpRequestOptions {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;

    const options: http.HttpRequestOptions = {
      readTimeout: transferTimeout,
      connectTimeout: connectTimeout,
      // Moonlight 协议要求响应新鲜（serverinfo/applist 等），禁用系统 HTTP 缓存
      usingCache: false,
      expectDataType: binaryResponse ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      // 自签名证书（Sunshine）默认跳过验证，与原 rcp remoteValidation:'skip' 语义一致
      remoteValidation: sessionOptions.skipServerValidation ? 'skip' : 'system'
    };

    if (method === 'PATCH') {
      // HttpMethod 枚举无 PATCH，用 customMethod 透传（API 23+）
      options.customMethod = 'PATCH';
    } else {
      options.method = HttpClient.mapMethod(method);
    }

    const headers = HttpClient.normalizeHeaders(config?.headers);
    if (headers) {
      options.header = headers;
    }
    if (body !== undefined) {
      options.extraData = body;
    }
    if (binaryResponse) {
      options.maxLimit = HttpClient.MAX_BINARY_BYTES;
    }
    if (sessionOptions.clientCertPath && sessionOptions.clientKeyPath) {
      options.clientCert = {
        certPath: sessionOptions.clientCertPath,
        certType: http.CertType.PEM,
        keyPath: sessionOptions.clientKeyPath
      };
    }
    return options;
  }

  private static mapMethod(method: HttpMethod): http.RequestMethod {
    switch (method) {
      case 'GET':
        return http.RequestMethod.GET;
      case 'POST':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      case 'HEAD':
        return http.RequestMethod.HEAD;
      default:
        return http.RequestMethod.GET;
    }
  }

  static normalizeHeaders(headers?: Record<string, string>): Record<string, string> | undefined {
    if (!headers) {
      return undefined
    }

    const entries = Object.entries(headers)
    if (entries.length === 0) {
      return undefined
    }

    const normalized: Record<string, string> = {}
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i]
      const key = entry[0]
      const value = entry[1]
      if (!key || value === undefined || value === null) {
        continue
      }
      normalized[key] = String(value)
    }

    return Object.keys(normalized).length > 0 ? normalized : undefined
  }

  /**
   * 将请求体转换为精确的 ArrayBuffer，避免 TypedArray 的 byteOffset/byteLength 干扰。
   */
  private static toExactArrayBuffer(data: ArrayBuffer | Uint8Array): ArrayBuffer {
    if (data instanceof Uint8Array) {
      return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)
    }
    return data
  }

  /** BinaryHttpSession 与 HttpClient 共用（ArkTS 无包级可见性） */
  static destroyQuietly(request: http.HttpRequest): void {
    try {
      request.destroy();
    } catch (_err) {
      // destroy 失败无需处理：请求对象随后由 GC 回收
    }
  }

  /**
   * 归一化错误描述。
   *
   * @ohos.net.http 的失败以 BusinessError(code=23000xx) 抛出（2300000 + curl 码）。
   * 为让下游基于关键词的错误分类器（NvHttp.isTransientNetworkError 等）继续工作，
   * 统一输出「Error code: <code>, <英文关键词描述>」格式，与原 rcp 消息风格对齐。
   */
  static describeError(err: Object | undefined): string {
    const e = (err ?? {}) as HttpErrorLike;
    const code = typeof e.code === 'number' ? e.code : 0;
    if (code >= 2300000 && code <= 2300999) {
      const detail = HttpClient.detailForCode(code);
      return detail ? `Error code: ${code}, ${detail}` : `Error code: ${code}`;
    }
    return e.message ?? String(err);
  }

  private static detailForCode(code: number): string {
    switch (code) {
      case 2300006:
        return "Couldn't resolve host name (DNS failure)";
      case 2300007:
        return "Couldn't connect to server (connection refused)";
      case 2300016:
        return 'HTTP/2 framing layer error';
      case 2300028:
        return 'Operation timeout';
      case 2300035:
        return 'SSL handshake failed';
      case 2300042:
        return 'Request canceled';
      case 2300051:
        return 'SSL peer certificate verification failed';
      case 2300052:
        return 'Server returned nothing (empty reply)';
      case 2300060:
        return 'SSL peer certificate cannot be verified';
      default:
        return '';
    }
  }

  private static isTimeoutError(msg: string): boolean {
    if (!msg) return false;
    return msg.toLowerCase().includes('timeout');
  }

  private static makeCanceledErrorInternal(): Error {
    const e = new Error('Request canceled') as CancelableError;
    e.name = 'CanceledError';
    e.isCanceled = true;
    return e;
  }

  /** BinaryHttpSession 与 HttpClient 共用的取消错误工厂（ArkTS 无包级可见性） */
  static makeCanceledError(): Error {
    return HttpClient.makeCanceledErrorInternal();
  }

  /**
   * 通用请求执行器：发请求并返回状态码 + 原始响应体
   */
  private static async performRequest(
    method: HttpMethod,
    url: string,
    body: string | ArrayBuffer | undefined,
    config: HttpClientConfig | undefined,
    binaryResponse: boolean
  ): Promise<RawResponse> {
    const connectTimeout = config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT;
    const transferTimeout = config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT;
    const certSuffix = config?.clientCertPath ? ', mTLS' : '';

    Logger.debug('HttpClient', `HttpClient: ${method} ${url} (connect=${connectTimeout}ms, transfer=${transferTimeout}ms${certSuffix})`);

    const request = http.createHttp();
    try {
      const sessionOptions: HttpSessionOptions = {
        skipServerValidation: config?.skipServerValidation !== false,
        clientCertPath: config?.clientCertPath,
        clientKeyPath: config?.clientKeyPath
      };
      const options = HttpClient.buildRequestOptions(method, config, body, sessionOptions, binaryResponse);
      const response = await request.request(url, options);
      Logger.debug('HttpClient', `HttpClient: 响应状态码 = ${response.responseCode}`);
      const raw: RawResponse = { statusCode: response.responseCode, raw: response.result as string | ArrayBuffer };
      return raw;
    } catch (err) {
      const detail = HttpClient.describeError(err as Object);
      if (HttpClient.isTimeoutError(detail)) {
        Logger.warn('HttpClient', `HttpClient: 请求超时 - ${url}`);
      } else {
        Logger.error('HttpClient', `HttpClient: 请求失败 - ${detail}`);
      }
      throw new Error(`HTTP 请求失败: ${detail}`);
    } finally {
      HttpClient.destroyQuietly(request);
    }
  }

  /**
   * 执行 GET 请求（文本响应）
   */
  private static async executeGet(url: string, config?: HttpClientConfig): Promise<HttpResponse> {
    const result = await HttpClient.performRequest('GET', url, undefined, config, false);
    if (result.statusCode !== 200) {
      throw new Error(`HTTP ${result.statusCode}`);
    }
    const body = result.raw as string;
    if (!body) {
      throw new Error('响应体为空');
    }
    return { statusCode: result.statusCode, body: body };
  }

  /**
   * 执行 GET 请求
   * @param url 请求 URL
   * @param config 配置选项
   * @returns 响应字符串
   */
  static async get(url: string, config?: HttpClientConfig): Promise<string> {
    const response = await HttpClient.executeGet(url, config);
    return response.body;
  }

  /**
   * 执行 HTTP 请求（GET，返回完整响应）
   */
  static async request(url: string, config?: HttpClientConfig): Promise<HttpResponse> {
    return HttpClient.executeGet(url, config);
  }

  /**
   * 执行原始 HTTP 请求，保留状态码并允许空响应体。
   * 适用于 GitHub Star 检查这类用 204/404 表达业务结果的 API。
   */
  static async requestRaw(
    url: string,
    method: HttpMethod,
    body?: string,
    config?: HttpClientConfig
  ): Promise<HttpResponse> {
    const result = await HttpClient.performRequest(method, url, body, config, false);
    return { statusCode: result.statusCode, body: result.raw as string };
  }

  /**
   * 执行带客户端证书的 HTTPS 请求
   * @param url 请求 URL
   * @param certPath 证书文件路径
   * @param keyPath 私钥文件路径
   * @param config 配置选项
   * @returns 响应字符串
   */
  static async getWithClientCert(
    url: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<string> {
    return HttpClient.get(url, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT
    });
  }

  /**
   * 执行 GET 请求并返回二进制数据
   */
  static async getBinary(url: string, config?: HttpClientConfig): Promise<ArrayBuffer> {
    const result = await HttpClient.performRequest('GET', url, undefined, config, true);
    if (result.statusCode !== 200) {
      throw new Error(`HTTP ${result.statusCode}`);
    }
    const body = result.raw as ArrayBuffer;
    if (!body || body.byteLength === 0) {
      throw new Error('响应体为空');
    }
    Logger.info('HttpClient', `HttpClient: 二进制响应大小 = ${body.byteLength} 字节`);
    return body;
  }

  /**
   * 执行带客户端证书的 HTTPS 请求并返回二进制数据
   * @param url 请求 URL
   * @param certPath 证书文件路径
   * @param keyPath 私钥文件路径
   * @param config 配置选项
   * @returns ArrayBuffer
   */
  static async getBinaryWithClientCert(
    url: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<ArrayBuffer> {
    return HttpClient.getBinary(url, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      headers: config?.headers,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? HttpClient.DEFAULT_TRANSFER_TIMEOUT
    });
  }

  /**
   * 执行 POST 请求（JSON body）
   */
  static async post(url: string, body: string, config?: HttpClientConfig): Promise<HttpResponse> {
    const result = await HttpClient.performRequest('POST', url, body, config, false);
    if (!result.raw) {
      throw new Error('响应体为空');
    }
    return { statusCode: result.statusCode, body: result.raw as string };
  }

  /**
   * 执行 POST 请求（二进制 body）。
   */
  static async postBinary(url: string, body: ArrayBuffer | Uint8Array, config?: HttpClientConfig): Promise<HttpResponse> {
    const requestBody = HttpClient.toExactArrayBuffer(body);
    const result = await HttpClient.performRequest('POST', url, requestBody, config, false);
    if (result.statusCode < 200 || result.statusCode >= 300) {
      throw new Error(`HTTP ${result.statusCode}`);
    }
    return { statusCode: result.statusCode, body: result.raw as string };
  }

  /**
   * 执行带客户端证书的 POST 请求
   */
  static async postWithClientCert(
    url: string,
    body: string,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<HttpResponse> {
    return HttpClient.post(url, body, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      headers: config?.headers,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? 120000
    });
  }

  /**
   * 执行带客户端证书的二进制 POST 请求。
   */
  static async postBinaryWithClientCert(
    url: string,
    body: ArrayBuffer | Uint8Array,
    certPath: string,
    keyPath: string,
    config?: HttpClientConfig
  ): Promise<HttpResponse> {
    return HttpClient.postBinary(url, body, {
      skipServerValidation: true,
      clientCertPath: certPath,
      clientKeyPath: keyPath,
      headers: config?.headers,
      connectTimeout: config?.connectTimeout ?? HttpClient.DEFAULT_CONNECT_TIMEOUT,
      transferTimeout: config?.transferTimeout ?? 120000
    });
  }
}
