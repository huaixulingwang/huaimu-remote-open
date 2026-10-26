/*
 * 统一账号登录页
 *
 * 原生表单 + 系统 HTTP（不使用内嵌网页 / JS SDK），
 * 接口与字段见 account-center/接入说明.md 第 3 节。
 *
 * UI 验收要点：
 * - 格式提示常驻显示在输入框下方（12fp，颜色不过浅），不只放 placeholder
 * - 手机号只允许数字、最多 11 位，左侧固定 +86
 * - 提交前本地校验，不满足格式时不发请求
 * - 错误红字显示在对应输入框下方
 * - 不出现自建注册体系、不收集密码（密码只在账号中心设置）
 */

import { AppNav } from '../common/AppNav';
import { AppColors, AppSizes } from '../common/Theme';
import { AccountCenterService } from '../service/account/AccountCenterService';
import { ToastQueue } from '../utils/ToastQueue';
import { Logger } from '../common/Logger';

const TAG: string = 'AccountLoginPage';

@Component
struct AccountLoginPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;

  @State phone: string = '';
  @State smsCode: string = '';
  @State password: string = '';
  @State nickname: string = '';
  @State mode: string = 'sms';          // sms | password
  @State verificationId: string = '';
  @State isRegisteredUser: boolean = true;
  @State smsSent: boolean = false;
  @State countdown: number = 0;
  @State busy: boolean = false;
  @State passwordVisible: boolean = false;

  // 字段级错误（显示在对应输入框下方）
  @State phoneError: string = '';
  @State smsError: string = '';
  @State accountError: string = '';
  @State passwordError: string = '';
  @State nicknameError: string = '';
  // 与具体输入框无关的错误（网络失败、验证码过期等）
  @State formError: string = '';

  private countdownTimer: number = -1;

  aboutToDisappear(): void {
    if (this.countdownTimer > 0) {
      clearInterval(this.countdownTimer);
      this.countdownTimer = -1;
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.NavBar()

        Scroll() {
          Column() {
            Text('统一账号')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.TextPrimary)
              .margin({ top: 24 })

            Text('一个账号，通用全部产品')
              .fontSize(14)
              .fontColor(AppColors.TextSecondary)
              .margin({ top: 8, bottom: 28 })

            this.ModeSwitch()

            if (this.mode === 'sms') {
              this.SmsForm()
            } else {
              this.PasswordForm()
            }

            if (this.formError.length > 0) {
              Text(this.formError)
                .fontSize(13)
                .fontColor('#E5484D')
                .width('100%')
                .margin({ top: 16 })
                .textAlign(TextAlign.Start)
            }

            this.SubmitButton()

            Text('登录即代表同意账号服务条款。账号仅用于设备绑定与云端功能，不读取通讯录、位置等信息。')
              .fontSize(12)
              .fontColor(AppColors.TextSecondary)
              .width('100%')
              .margin({ top: 20 })
              .lineHeight(18)
          }
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 40 })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColors.Background)
    }
    .hideTitleBar(true)
    .backgroundColor(AppColors.Background)
  }

  @Builder
  NavBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([AppColors.TextPrimary])
        .onClick(() => AppNav.pop())

      Text('登录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.TextPrimary)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Blank().width(22)
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 20 })
    .margin({ top: this.topSafeHeight })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ModeSwitch() {
    Row() {
      this.ModeTab('验证码登录', 'sms')
      this.ModeTab('密码登录', 'password')
    }
    .width('100%')
    .height(44)
    .padding(4)
    .backgroundColor(AppColors.Surface)
    .borderRadius(AppSizes.RadiusMedium)
    .margin({ bottom: 24 })
  }

  @Builder
  ModeTab(label: string, value: string) {
    Text(label)
      .fontSize(14)
      .fontWeight(this.mode === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.mode === value ? AppColors.TextPrimary : AppColors.TextSecondary)
      .textAlign(TextAlign.Center)
      .height(36)
      .layoutWeight(1)
      .borderRadius(AppSizes.RadiusSmall)
      .backgroundColor(this.mode === value ? AppColors.CardBackgroundActive : Color.Transparent)
      .onClick(() => {
        if (this.busy) {
          return;
        }
        this.mode = value;
        this.clearErrors();
      })
  }

  @Builder
  SmsForm() {
    Column() {
      this.FieldLabel('手机号')

      // 左侧固定 +86，右侧只输入 11 位数字
      Row() {
        Text('+86')
          .fontSize(16)
          .fontColor(AppColors.TextPrimary)
          .width(52)
          .textAlign(TextAlign.Center)

        Divider()
          .vertical(true)
          .height(22)
          .color(AppColors.Divider)

        TextInput({ text: this.phone, placeholder: '11 位手机号' })
          .type(InputType.Number)
          .maxLength(11)
          .height(52)
          .fontSize(16)
          .fontColor(AppColors.TextPrimary)
          .placeholderColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .padding({ left: 12, right: 12 })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.phone = value.replace(/\D/g, '').slice(0, 11);
            this.phoneError = '';
          })
      }
      .width('100%')
      .height(52)
      .backgroundColor(AppColors.Surface)
      .borderRadius(AppSizes.RadiusMedium)

      this.Hint('请输入 11 位手机号，系统会自动加 +86')
      this.FieldError(this.phoneError)

      Row() {
        Column() {
          this.FieldLabel('验证码')
          TextInput({ text: this.smsCode, placeholder: '6 位数字' })
            .type(InputType.Number)
            .maxLength(6)
            .height(52)
            .fontSize(16)
            .fontColor(AppColors.TextPrimary)
            .placeholderColor(AppColors.TextSecondary)
            .backgroundColor(AppColors.Surface)
            .borderRadius(AppSizes.RadiusMedium)
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.smsCode = value.replace(/\D/g, '').slice(0, 6);
              this.smsError = '';
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.countdown > 0 ? `${this.countdown}s 后重发` : '获取验证码')
          .fontSize(13)
          .fontColor(this.canSendCode() ? AppColors.Primary : AppColors.TextSecondary)
          .backgroundColor(AppColors.Surface)
          .height(52)
          .width(116)
          .borderRadius(AppSizes.RadiusMedium)
          .margin({ left: 10, top: 24 })
          .enabled(this.canSendCode())
          .onClick(() => {
            this.sendCode();
          })
      }
      .width('100%')
      .margin({ top: 16 })

      this.Hint('6 位数字验证码，60 秒内有效')
      this.FieldError(this.smsError)

      if (this.smsSent && !this.isRegisteredUser) {
        this.FieldLabel('昵称（新账号）')
        TextInput({ text: this.nickname, placeholder: '你希望别人看到的名字' })
          .height(52)
          .maxLength(64)
          .fontSize(16)
          .fontColor(AppColors.TextPrimary)
          .placeholderColor(AppColors.TextSecondary)
          .backgroundColor(AppColors.Surface)
          .borderRadius(AppSizes.RadiusMedium)
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.nickname = value;
            this.nicknameError = '';
          })
          .margin({ top: 16 })

        this.Hint('2–64 个字符，可稍后修改')
        this.FieldError(this.nicknameError)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PasswordForm() {
    Column() {
      this.FieldLabel('账号')

      TextInput({ text: this.phone, placeholder: '用户名、邮箱或手机号' })
        .height(52)
        .fontSize(16)
        .fontColor(AppColors.TextPrimary)
        .placeholderColor(AppColors.TextSecondary)
        .backgroundColor(AppColors.Surface)
        .borderRadius(AppSizes.RadiusMedium)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.phone = value;
          this.accountError = '';
        })

      this.Hint('用户名、邮箱或手机号；手机号会自动补 +86')
      this.FieldError(this.accountError)

      this.FieldLabel('密码')

      Row() {
        TextInput({ text: this.password, placeholder: '请输入密码' })
          .type(this.passwordVisible ? InputType.Normal : InputType.Password)
          .height(52)
          .fontSize(16)
          .fontColor(AppColors.TextPrimary)
          .placeholderColor(AppColors.TextSecondary)
          .backgroundColor(Color.Transparent)
          .padding({ left: 16, right: 8 })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.password = value;
            this.passwordError = '';
          })

        Text(this.passwordVisible ? '隐藏' : '显示')
          .fontSize(13)
          .fontColor(AppColors.Primary)
          .padding({ left: 8, right: 16 })
          .onClick(() => {
            this.passwordVisible = !this.passwordVisible;
          })
      }
      .width('100%')
      .height(52)
      .backgroundColor(AppColors.Surface)
      .borderRadius(AppSizes.RadiusMedium)
      .margin({ top: 8 })

      this.FieldError(this.passwordError)

      Text('忘记密码请到账号中心，用手机号验证码登录后重设')
        .fontSize(12)
        .fontColor('#9AA4B2')
        .width('100%')
        .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FieldLabel(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(AppColors.TextSecondary)
      .width('100%')
      .margin({ top: 16, bottom: 8 })
      .textAlign(TextAlign.Start)
  }

  /** 常驻格式提示：12fp，颜色不过浅 */
  @Builder
  Hint(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#9AA4B2')
      .width('100%')
      .margin({ top: 8 })
      .textAlign(TextAlign.Start)
  }

  @Builder
  FieldError(text: string) {
    if (text.length > 0) {
      Text(text)
        .fontSize(12)
        .fontColor('#E5484D')
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)
    }
  }

  @Builder
  SubmitButton() {
    Button(this.busy ? '请稍候…' : (this.mode === 'sms' ? '登录 / 注册' : '登录'))
      .width('100%')
      .height(50)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FFFFFF')
      .backgroundColor(AppColors.Primary)
      .borderRadius(AppSizes.RadiusMedium)
      .margin({ top: 28 })
      .enabled(this.canSubmit())
      .opacity(this.canSubmit() ? 1 : 0.5)
      .onClick(() => {
        this.submit();
      })
  }

  private clearErrors(): void {
    this.phoneError = '';
    this.smsError = '';
    this.accountError = '';
    this.passwordError = '';
    this.nicknameError = '';
    this.formError = '';
  }

  private phoneDigits(): string {
    return this.phone.replace(/\D/g, '');
  }

  private canSendCode(): boolean {
    return !this.busy && this.countdown <= 0 && this.phoneDigits().length === 11;
  }

  private canSubmit(): boolean {
    if (this.busy) {
      return false;
    }
    if (this.mode === 'sms') {
      return this.phoneDigits().length === 11 && this.smsCode.length === 6;
    }
    return this.phone.trim().length > 0 && this.password.length > 0;
  }

  private startCountdown(): void {
    this.countdown = 60;
    if (this.countdownTimer > 0) {
      clearInterval(this.countdownTimer);
    }
    this.countdownTimer = setInterval(() => {
      if (this.countdown <= 1) {
        this.countdown = 0;
        clearInterval(this.countdownTimer);
        this.countdownTimer = -1;
      } else {
        this.countdown -= 1;
      }
    }, 1000);
  }

  private async sendCode(): Promise<void> {
    this.clearErrors();
    if (this.phoneDigits().length !== 11) {
      this.phoneError = '请输入 11 位手机号';
      return;
    }
    this.busy = true;
    try {
      const phone = AccountCenterService.normalizePhone(this.phoneDigits());
      const result = await AccountCenterService.sendVerificationCode(phone);
      this.verificationId = result.verification_id;
      this.isRegisteredUser = result.is_user;
      this.smsSent = true;
      this.startCountdown();
      ToastQueue.show({
        message: result.is_user ? '验证码已发送，请查收短信' : '验证码已发送，验证后将自动创建账号',
        duration: 3000
      });
    } catch (err) {
      this.formError = (err as Error).message;
      Logger.warn(TAG, `发送验证码失败: ${this.formError}`);
    } finally {
      this.busy = false;
    }
  }

  private async submit(): Promise<void> {
    this.clearErrors();
    if (!this.canSubmit()) {
      return;
    }

    if (this.mode === 'sms') {
      if (this.verificationId.length === 0) {
        this.smsError = '请先获取验证码';
        return;
      }
      if (this.smsCode.length !== 6) {
        this.smsError = '请输入 6 位数字验证码';
        return;
      }
      if (!this.isRegisteredUser) {
        const name = this.nickname.trim();
        if (name.length > 0 && (name.length < 2 || name.length > 64)) {
          this.nicknameError = '昵称需要 2–64 个字符';
          return;
        }
      }
    } else {
      if (this.phone.trim().length === 0) {
        this.accountError = '请输入账号';
        return;
      }
      if (this.password.length === 0) {
        this.passwordError = '请输入密码';
        return;
      }
    }

    this.busy = true;
    try {
      if (this.mode === 'password') {
        await this.loginWithPassword();
      } else {
        await this.loginWithSms();
      }
      this.busy = false;
      ToastQueue.show({ message: '登录成功', duration: 2000 });
      AccountCenterService.syncAccountInfo();
      // 登录成功即把这台平板登记到账号设备名单（后台进行，失败不影响使用）
      AccountCenterService.registerThisDevice();
      AppNav.pop();
      return;
    } catch (err) {
      const message = (err as Error).message;
      this.formError = message;
      Logger.warn(TAG, `登录失败: ${message}`);
    }
    this.busy = false;
  }

  private async loginWithPassword(): Promise<void> {
    await AccountCenterService.signInWithPassword(this.phone.trim(), this.password);
  }

  private async loginWithSms(): Promise<void> {
    const phone = AccountCenterService.normalizePhone(this.phoneDigits());
    let verificationToken: string = '';
    try {
      verificationToken = await AccountCenterService.verifyCode(this.verificationId, this.smsCode);
    } catch (err) {
      // 验证码校验失败统一中文提示，不暴露服务端英文原文
      throw new Error('验证码不正确或已过期，请重新获取');
    }
    if (this.isRegisteredUser) {
      await AccountCenterService.signInWithCode(phone, verificationToken);
    } else {
      const name = this.nickname.trim().length > 0 ? this.nickname.trim() : '远控用户';
      await AccountCenterService.signUpWithCode(phone, this.smsCode, verificationToken, name);
    }
  }
}

@Builder
export function AccountLoginPageBuilder() {
  AccountLoginPage()
}
