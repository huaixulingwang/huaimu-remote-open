/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 网络相关常量
 * Sunshine/GFE 默认端口及网络限制
 */

/** Sunshine/GFE 默认 HTTP 端口 */
export const DEFAULT_HTTP_PORT = 47989;

/** Sunshine/GFE 默认 HTTPS 端口 */
export const DEFAULT_HTTPS_PORT = 47984;

/**
 * OpenRemoteDesk自有串流实例的端口段（与社区版 Sunshine 完全分开）。
 * 电脑端安装包会同时装两套：社区版 47989 段、我们自己 48989 段。
 */
export const LINGWANG_HTTP_PORT = 48989;
export const LINGWANG_HTTPS_PORT = 48984;

/**
 * 电脑端虚拟地址段：同一账号下每台电脑一个不同地址（10.126.126.1 或 .4~250）。
 * .2 留给外部 EasyTier App，.3 留给平板，都不算电脑端。
 */
export const LINGWANG_HOST_VIRTUAL_IP = '10.126.126.1';

/** 判断某个地址是不是OpenRemoteDesk电脑端的虚拟地址 */
export function isLingWangHostAddress(address: string): boolean {
  const prefix: string = '10.126.126.';
  if (address.length <= prefix.length || !address.startsWith(prefix)) {
    return false;
  }
  const last: number = Number(address.substring(prefix.length));
  if (Number.isNaN(last)) {
    return false;
  }
  return last >= 1 && last <= 250 && last !== 2 && last !== 3;
}

/** 有效端口号上限 */
export const MAX_PORT = 65535;
