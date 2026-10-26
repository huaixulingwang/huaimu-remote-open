/*
 * 输入电脑端临时控制码
 *
 * 触发场景：平板与电脑不同账号（或平板未登录），电脑端已绑定账号。
 * 用户在电脑端主界面点「生成」拿到 6 位控制码，在这里输入即可临时连接。
 */

import { AppNav } from '../common/AppNav';
import { AppColors, AppSizes } from '../common/Theme';
import { AccessCodePageParams, StreamPageParams } from '../common/PageParams';
import { AccessGate } from '../service/network/AccessGate';
import { ToastQueue } from '../utils/ToastQueue';
import { Logger } from '../common/Logger';

const TAG: string = 'AccessCodePage';

@Component
struct AccessCodePage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;

  @State code: string = '';
  @State busy: boolean = false;
  @State errorText: string = '';

  private params: AccessCodePageParams = {
    host: '',
    computerId: '',
    computerName: '',
    reason: '',
    stream: { computerId: '', appId: 0 }
  };

  aboutToAppear(): void {
    try {
      this.params = AppNav.topParams<AccessCodePageParams>();
    } catch (err) {
      Logger.warn(TAG, `读取路由参数失败: ${(err as Error).message}`);
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.NavBar()

        Column() {
          Text('输入控制码')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.TextPrimary)
            .margin({ top: 28 })

          Text(this.reasonText())
            .fontSize(14)
            .fontColor(AppColors.TextSecondary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .lineHeight(20)
            .margin({ top: 10, bottom: 28 })

          TextInput({ text: this.code, placeholder: '6 位数字' })
            .type(InputType.Number)
            .maxLength(6)
            .height(72)
            .width('100%')
            .fontSize(30)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(8)
            .textAlign(TextAlign.Center)
            .fontColor(AppColors.TextPrimary)
            .placeholderColor(AppColors.TextTertiary)
            .backgroundColor(AppColors.Surface)
            .borderRadius(AppSizes.RadiusMedium)
            .onChange((value: string) => {
              this.code = value.replace(/\D/g, '').slice(0, 6);
              this.errorText = '';
            })

          Text('在电脑端主界面点「生成」，控制码 10 分钟内有效')
            .fontSize(12)
            .fontColor('#9AA4B2')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 10 })

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(13)
              .fontColor('#E5484D')
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 14 })
          }

          Button(this.busy ? '正在验证…' : '连接这台电脑')
            .width('100%')
            .height(50)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor(AppColors.Primary)
            .borderRadius(AppSizes.RadiusMedium)
            .margin({ top: 28 })
            .enabled(!this.busy && this.code.length === 6)
            .opacity(!this.busy && this.code.length === 6 ? 1 : 0.5)
            .onClick(() => {
              this.submit();
            })

          Text('也可以在设置 → 账号里登录与电脑相同的账号，之后直接连接')
            .fontSize(12)
            .fontColor('#9AA4B2')
            .width('100%')
            .textAlign(TextAlign.Center)
            .lineHeight(18)
            .margin({ top: 18 })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
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

      Text('控制码连接')
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

  private reasonText(): string {
    const name: string = this.params.computerName.length > 0 ? this.params.computerName : '这台电脑';
    if (this.params.reason.length > 0) {
      return `${name}：${this.params.reason}`;
    }
    return `${name}已绑定统一账号，需要控制码才能连接`;
  }

  private async submit(): Promise<void> {
    if (this.busy || this.code.length !== 6) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const result = await AccessGate.verifyCode(this.params.host, this.code);
      if (result.ok) {
        const stream: StreamPageParams = this.params.stream;
        // 用串流页替换当前页，返回时直接回首页，不会又回到码页
        AppNav.stack.replacePathByName('StreamPage', stream);
        ToastQueue.show({ message: '控制码正确，开始连接', duration: 2000 });
      } else {
        this.errorText = result.reason;
      }
    } catch (err) {
      this.errorText = '无法连接电脑，请确认组网正常后重试';
      Logger.warn(TAG, `控制码校验失败: ${(err as Error).message}`);
    }
    this.busy = false;
  }
}

@Builder
export function AccessCodePageBuilder() {
  AccessCodePage()
}
