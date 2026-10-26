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
 * 串流页面 IME 键盘管理器
 *
 * 封装系统输入法键盘的显示/隐藏、输入回调等逻辑，
 * 从 StreamPage 中解耦以降低单文件复杂度。
 */
import { window } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { UI } from '../../common/UI';
import { StreamViewModel } from '../../viewmodel/StreamViewModel';
import { Logger } from '../../common/Logger';
import { FileLog } from '../networking/FileLog';

/**
 * StreamPage 需要实现的 IME 回调接口
 * 用于将键盘状态变化同步到 StreamPage 的 @State 变量
 */
export interface IMECallbacks {
  /** 键盘可见性变化 */
  onKeyboardVisibilityChanged: (visible: boolean) => void;
  /** 键盘高度变化（vp） */
  onKeyboardHeightChanged: (height: number) => void;
}

export class StreamIMEManager {
  // ── 输入法控制器 ──
  private imeController: inputMethod.InputMethodController | null = null;
  private showInProgress: boolean = false;
  private showRequestId: number = 0;
  private imeReadyTime: number = 0;
  /** 锁定模式：开启后点击其他区域不会收起 IME / IME bar，HIDE 事件会被拦截并重新唤起软键盘 */
  private locked: boolean = false;

  // ── 静默 attach（物理蓝牙键盘捕获）──
  /** 静默模式下的独立 controller，不弹软键盘，仅接收被输入法框架拦截的物理键盘输入 */
  private silentController: inputMethod.InputMethodController | null = null;
  /** 诊断：兜底通道累计收到的文字段数（只在兜底模式下增长；停滞=兜底也没在收字） */
  private silentTextCount: number = 0;

  // ── 外部依赖 ──
  private viewModel: StreamViewModel | null = null;
  private callbacks: IMECallbacks | null = null;
  private context: Context;

  constructor(context: Context) {
    this.context = context;
  }

  /**
   * 初始化依赖项
   */
  initialize(viewModel: StreamViewModel, callbacks: IMECallbacks): void {
    this.viewModel = viewModel;
    this.callbacks = callbacks;
  }

  /**
   * IME 就绪时间戳（防止弹出瞬间 onBackPress 误关）
   */
  get readyTime(): number {
    return this.imeReadyTime;
  }

  /**
   * 当前是否处于锁定模式
   */
  get isLocked(): boolean {
    return this.locked;
  }

  /**
   * 设置锁定模式。锁定后系统 IME 被点击外部关闭时会自动重新唤起，
   * 避免 IME bar 随之消失。仅影响 HIDE 回调，不影响主动 hide() / backPress 逻辑。
   */
  setLocked(locked: boolean): void {
    this.locked = locked;
  }

  /**
   * 使用 InputMethod API 直接显示系统键盘（无需 TextInput 组件）
   * 节省屏幕空间，串流画面完整可见
   */
  async show(): Promise<void> {
    const session = this.viewModel?.getSession();
    if (!session || this.showInProgress || this.imeController) return;

    const requestId = ++this.showRequestId;
    this.showInProgress = true;
    let win: window.Window | null = null;
    let controller: inputMethod.InputMethodController | null = null;

    try {
      // 监听键盘高度变化
      win = await window.getLastWindow(this.context);
      if (requestId !== this.showRequestId) return;
      win.on('keyboardHeightChange', (height: number) => {
        this.callbacks?.onKeyboardHeightChanged(UI.get().px2vp(height));
      });

      controller = inputMethod.getController();

      // 先绑定输入法（必须先 attach 才能注册回调）
      const textConfig: inputMethod.TextConfig = {
        inputAttribute: {
          textInputType: inputMethod.TextInputType.TEXT,
          enterKeyType: inputMethod.EnterKeyType.SEND
        }
      };
      await controller.attach(true, textConfig);
      if (requestId !== this.showRequestId) {
        controller.detach();
        win.off('keyboardHeightChange');
        return;
      }

      // attach 成功后注册输入回调
      controller.on('insertText', (text: string) => {
        // 临时诊断：确认哪些字符经输入法投递（排查数字键等）
        Logger.info('StreamIMEManager', `[KB-DIAG] insertText: "${text}"`);
        session.sendUtf8Text(text);
      });

      controller.on('deleteLeft', (length: number) => {
        for (let i = 0; i < length; i++) {
          session.sendKeyboardInput(0x08, 0x03); // VK_BACK DOWN
          session.sendKeyboardInput(0x08, 0x04); // VK_BACK UP
        }
      });

      controller.on('deleteRight', (length: number) => {
        for (let i = 0; i < length; i++) {
          session.sendKeyboardInput(0x2E, 0x03); // VK_DELETE DOWN
          session.sendKeyboardInput(0x2E, 0x04); // VK_DELETE UP
        }
      });

      controller.on('sendFunctionKey', (key: inputMethod.FunctionKey) => {
        session.sendKeyboardInput(0x0D, 0x03); // VK_RETURN DOWN
        session.sendKeyboardInput(0x0D, 0x04); // VK_RETURN UP
      });

      // 物理键盘方向键被输入法框架转为光标移动回调投递
      controller.on('moveCursor', (direction: inputMethod.Direction) => {
        Logger.info('StreamIMEManager', `[KB-DIAG] moveCursor: ${direction}`);
        let vk = 0;
        switch (direction) {
          case inputMethod.Direction.CURSOR_UP: vk = 0x26; break;    // VK_UP
          case inputMethod.Direction.CURSOR_DOWN: vk = 0x28; break;  // VK_DOWN
          case inputMethod.Direction.CURSOR_LEFT: vk = 0x25; break;  // VK_LEFT
          case inputMethod.Direction.CURSOR_RIGHT: vk = 0x27; break; // VK_RIGHT
          default: return;
        }
        session.sendKeyboardInput(vk, 0x03);
        session.sendKeyboardInput(vk, 0x04);
      });

      controller.on('sendKeyboardStatus', (status: inputMethod.KeyboardStatus) => {
        // 只响应用户主动关闭键盘的 HIDE 事件
        // 忽略 attach 初始化阶段的假 HIDE（部分设备会在显示前先发一次 HIDE）
        if (status === inputMethod.KeyboardStatus.HIDE && Date.now() - this.imeReadyTime > 300) {
          // 锁定模式：拦截外部点击导致的收键盘，重新调起软键盘以保持 IME bar 常驻
          if (this.locked && this.imeController) {
            this.imeReadyTime = Date.now();
            this.imeController.showSoftKeyboard().catch((err: Error) => {
              Logger.warn('StreamIMEManager', `[StreamIME] re-show on locked failed: ${err.message}`);
            });
            return;
          }
          this.hide();
        }
      });

      // 完成 attach 和全部回调注册后再发布 controller，避免暴露半初始化状态。
      this.imeController = controller;
      this.callbacks?.onKeyboardVisibilityChanged(true);
      this.imeReadyTime = Date.now();
    } catch (err) {
      Logger.error('StreamIMEManager', `[StreamPage] Failed to show IME: ${JSON.stringify(err)}`);
      if (controller) {
        try {
          controller.detach();
        } catch (cleanupErr) {
          Logger.warn('StreamIMEManager', `[StreamIME] Failed to detach after show error: ${JSON.stringify(cleanupErr)}`);
        }
      }
      if (win) {
        try {
          win.off('keyboardHeightChange');
        } catch (cleanupErr) {
          Logger.warn('StreamIMEManager', `[StreamIME] Failed to remove height listener: ${JSON.stringify(cleanupErr)}`);
        }
      }
      this.imeController = null;
      this.locked = false;
      this.callbacks?.onKeyboardVisibilityChanged(false);
      this.callbacks?.onKeyboardHeightChanged(0);
    } finally {
      this.showInProgress = false;
    }
  }

  /**
   * 关闭系统键盘并清理回调
   */
  hide(): void {
    // 主动 hide 时释放锁定状态，避免下次 show 时锁定误传递
    this.showRequestId++;
    this.locked = false;
    try {
      if (this.imeController) {
        this.imeController.off('insertText');
        this.imeController.off('deleteLeft');
        this.imeController.off('sendFunctionKey');
        this.imeController.off('sendKeyboardStatus');
        this.imeController.detach();
        this.imeController = null;
      }
      // 取消键盘高度监听
      window.getLastWindow(this.context).then((win) => {
        win.off('keyboardHeightChange');
      });
    } catch (err) {
      Logger.error('StreamIMEManager', `[StreamPage] Failed to hide IME: ${JSON.stringify(err)}`);
    }
    this.callbacks?.onKeyboardVisibilityChanged(false);
    this.callbacks?.onKeyboardHeightChanged(0);
  }

  /**
   * 静默 attach IME：不弹软键盘，仅接收被系统输入法框架拦截的物理键盘输入。
   * 用于修复 HarmonyOS 7.0 蓝牙键盘事件被输入法框架拦截导致第三方 App 收不到的问题。
   * 串流成功后自动调用，退出时通过 detachSilent() 清理。
   */
  async attachSilent(): Promise<void> {
    const session = this.viewModel?.getSession();
    if (!session || this.silentController) return;

    try {
      const controller = inputMethod.getController();
      const textConfig: inputMethod.TextConfig = {
        inputAttribute: {
          textInputType: inputMethod.TextInputType.TEXT,
          enterKeyType: inputMethod.EnterKeyType.SEND
        }
      };
      // attach(false) 不弹软键盘
      await controller.attach(false, textConfig);

      controller.on('insertText', (text: string) => {
        // 诊断：兜底通道确实在收文字（只记首段，其余靠 20 秒状态行的计数体现）
        this.silentTextCount++;
        if (this.silentTextCount === 1) {
          FileLog.d('KB-DIAG', `兜底(输入法)通道生效，收到首段文字: "${text}"`);
        }
        session.sendUtf8Text(text);
      });

      controller.on('deleteLeft', (length: number) => {
        for (let i = 0; i < length; i++) {
          session.sendKeyboardInput(0x08, 0x03); // VK_BACK DOWN
          session.sendKeyboardInput(0x08, 0x04); // VK_BACK UP
        }
      });

      controller.on('sendFunctionKey', (key: inputMethod.FunctionKey) => {
        session.sendKeyboardInput(0x0D, 0x03); // VK_RETURN DOWN
        session.sendKeyboardInput(0x0D, 0x04); // VK_RETURN UP
      });

      this.silentController = controller;
      Logger.info('StreamIMEManager', '[StreamIME] Silent attach success');
      FileLog.d('KB-DIAG', '兜底(输入法)通道已静默接上');
    } catch (err) {
      Logger.error('StreamIMEManager', `[StreamIME] Silent attach failed: ${JSON.stringify(err)}`);
      FileLog.d('KB-DIAG', `兜底(输入法)通道接上失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 清理静默 attach 的 IME 绑定。
   */
  detachSilent(): void {
    if (this.silentController) {
      try {
        this.silentController.off('insertText');
        this.silentController.off('deleteLeft');
        this.silentController.off('deleteRight');
        this.silentController.off('sendFunctionKey');
        this.silentController.off('moveCursor');
        this.silentController.detach();
      } catch (err) {
        Logger.warn('StreamIMEManager', `[StreamIME] Silent detach error: ${JSON.stringify(err)}`);
      }
      this.silentController = null;
      FileLog.d('KB-DIAG', '兜底(输入法)通道已断开');
    }
  }

  /** 诊断：兜底通道累计收到的文字段数 */
  getSilentTextCount(): number {
    return this.silentTextCount;
  }
}
