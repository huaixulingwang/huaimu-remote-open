import { VpnController } from '../service/networking/VpnController';

/**
 * 连接中进度弹框
 * 一键连接全程显示：正在建立安全通道 → 等待电脑响应（带秒数）→ 准备串流。
 * 通过 AppStorage 全局状态控制显隐与文案：
 *  - connectingVisible: boolean
 *  - connectingText: string
 * 用户点"取消连接"会立即中断组网等待并拆除 VPN 通道。
 * 挂载点：PcListPageV2 根 Stack 顶层。
 */
@Component
export struct ConnectingDialog {
  @StorageLink('connectingVisible') visible: boolean = false;
  @StorageLink('connectingText') text: string = '正在连接…';
  @State elapsedSec: number = 0;
  private timerId: number = -1;

  private startTimer(): void {
    this.stopTimer();
    this.elapsedSec = 0;
    this.timerId = setInterval(() => {
      this.elapsedSec += 1;
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    if (this.visible) {
      Column() {
        Column() {
          LoadingProgress()
            .width(44)
            .height(44)
            .color('#007DFF')

          Text(this.text)
            .fontSize(16)
            .fontColor('#1A1A1A')
            .margin({ top: 14 })
            .textAlign(TextAlign.Center)

          Text(`已等待 ${this.elapsedSec} 秒`)
            .fontSize(13)
            .fontColor('#999999')
            .margin({ top: 6 })

          Button('取消连接')
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize(15)
            .margin({ top: 18 })
            .onClick(() => {
              VpnController.getInstance().cancelStart();
              this.visible = false;
            })
        }
        .padding(24)
        .borderRadius(16)
        .backgroundColor('#FFFFFF')
        .width(320)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('rgba(0,0,0,0.45)')
      .onAppear(() => this.startTimer())
      .onDisAppear(() => this.stopTimer())
    }
  }
}
