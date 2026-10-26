import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

/**
 * 文件日志工具：把 VPN/EasyTier 的关键日志写到本地文件，
 * 方便断开 hdc 后复查。
 * 日志路径：{cacheDir}/vpn-debug.log
 */
export class FileLog {
  private static ctx: common.Context | null = null;
  private static path: string = '';
  // 黑匣子：主界面心跳文件（覆盖写时间戳）与"上次主界面卡死"标记文件
  private static heartbeatPath: string = '';
  private static freezeFlagPath: string = '';

  static init(ctx: common.Context): void {
    FileLog.ctx = ctx;
    FileLog.path = `${ctx.cacheDir}/vpn-debug.log`;
    FileLog.heartbeatPath = `${ctx.cacheDir}/ui-heartbeat.txt`;
    FileLog.freezeFlagPath = `${ctx.cacheDir}/ui-frozen.flag`;
  }

  static d(tag: string, msg: string): void {
    const line = `[${new Date().toISOString()}] ${tag}: ${msg}\n`;
    FileLog.append(line);
  }

  private static append(line: string): void {
    try {
      if (!FileLog.ctx) return;
      const file = fileIo.openSync(FileLog.path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, line);
      fileIo.closeSync(file);
    } catch (_) {
      // 忽略写文件错误
    }
  }

  static getPath(): string {
    return FileLog.path;
  }

  // ── 黑匣子：主界面卡死取证 ─────────────────────────────
  // 主界面每 2 秒覆盖写一次心跳时间戳。主界面被卡住时心跳停止，
  // 最后一次时间戳即冻结时刻；扩展线程据此独立判定"主界面卡死"。

  /** 主界面心跳：覆盖写当前毫秒时间戳 */
  static writeHeartbeat(): void {
    if (!FileLog.ctx) {
      return;
    }
    try {
      const file = fileIo.openSync(FileLog.heartbeatPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, `${Date.now()}`);
      fileIo.closeSync(file);
    } catch (_) {
      // 心跳写失败不影响业务
    }
  }

  /** 心跳距今毫秒数；无心跳或读取失败返回 -1 */
  static readHeartbeatAgeMs(): number {
    const text = FileLog.readText(FileLog.heartbeatPath, 32);
    if (!text) {
      return -1;
    }
    const ms = Number.parseInt(text.trim(), 10);
    if (Number.isNaN(ms)) {
      return -1;
    }
    return Date.now() - ms;
  }

  /** 记下"主界面卡死"现场，供下次启动时提示用户 */
  static writeFreezeFlag(detail: string): void {
    if (!FileLog.ctx) {
      return;
    }
    try {
      const file = fileIo.openSync(FileLog.freezeFlagPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, `[${new Date().toISOString()}] ${detail}`);
      fileIo.closeSync(file);
    } catch (_) {
      // 标记写失败不影响业务
    }
  }

  /** 读取并清除卡死标记；无标记返回 '' */
  static consumeFreezeFlag(): string {
    const text = FileLog.readText(FileLog.freezeFlagPath, 512);
    if (!text) {
      return '';
    }
    try {
      fileIo.unlinkSync(FileLog.freezeFlagPath);
    } catch (_) {
      // 清理失败下次启动会再提示一次，无害
    }
    return text;
  }

  private static readText(path: string, maxBytes: number): string {
    if (!FileLog.ctx || !path) {
      return '';
    }
    try {
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(maxBytes);
      const len = fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      if (len <= 0) {
        return '';
      }
      // 必须按 UTF-8 解码：中文一个字占 3 个字节，
      // 以前按"一个字节当一个字符"拼字符串，中文就变成乱码
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, len));
    } catch (_) {
      return '';
    }
  }
}
