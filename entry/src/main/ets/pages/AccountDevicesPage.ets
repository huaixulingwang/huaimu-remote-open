/*
 * 账号下的设备名单
 *
 * 登录过的平板和电脑都会记录在统一账号下；这里可以查看并删除。
 * 删除只移除账号里的记录，不影响任何设备本机的登录和配对。
 */

import { AppNav } from '../common/AppNav';
import { AppColors, AppSizes } from '../common/Theme';
import { AccountCenterService, AccountDevice } from '../service/account/AccountCenterService';
import { LocalIdentity } from '../service/network/LocalIdentity';
import { ToastQueue } from '../utils/ToastQueue';
import { Logger } from '../common/Logger';
import { promptAction } from '@kit.ArkUI';

const TAG: string = 'AccountDevicesPage';

@Component
struct AccountDevicesPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;

  @State devices: AccountDevice[] = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @State selfId: string = '';

  aboutToAppear(): void {
    LocalIdentity.getClientId().then((id: string) => {
      this.selfId = id;
    }).catch(() => {});
    this.loadDevices();
  }

  private async loadDevices(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      this.devices = await AccountCenterService.fetchDevices();
    } catch (err) {
      this.devices = [];
      this.errorText = '设备名单加载失败，请确认已登录且网络正常';
      Logger.warn(TAG, `加载设备名单失败: ${(err as Error).message}`);
    }
    this.loading = false;
  }

  private deviceTypeLabel(type: string): string {
    if (type === 'pc') {
      return '电脑';
    }
    if (type === 'phone') {
      return '手机';
    }
    return '平板';
  }

  private lastSeenLabel(value?: string): string {
    if (value === undefined || value.length < 10) {
      return '';
    }
    return value.substring(0, 16).replace('T', ' ');
  }

  private confirmDelete(device: AccountDevice): void {
    promptAction.showDialog({
      title: '从账号移除设备',
      message: `确定把「${device.device_name}」从账号名单里删除吗？\n\n只移除名单记录，这台设备本机的登录和配对不受影响。`,
      buttons: [
        { text: '取消', color: '#A8B0B8' },
        { text: '删除', color: '#E5484D' }
      ]
    }).then(async (result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index !== 1) {
        return;
      }
      try {
        await AccountCenterService.deleteDevice(device.device_id);
        ToastQueue.show({ message: '已从账号移除' });
        await this.loadDevices();
      } catch (err) {
        ToastQueue.show({ message: `删除失败: ${(err as Error).message}` });
      }
    });
  }

  build() {
    NavDestination() {
      Column() {
        this.NavBar()

        Column() {
          Text('删除只移除账号里的记录；设备若仍在登录，下次上线会重新出现。')
            .fontSize(12)
            .fontColor(AppColors.TextTertiary)
            .width('100%')
            .lineHeight(18)
            .margin({ top: 6, bottom: 2 })

          if (this.loading) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(AppColors.Primary)
              .margin({ top: 80 })
          } else if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(14)
              .fontColor('#E5484D')
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 40 })
            Button('重试')
              .height(44)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .backgroundColor(AppColors.Primary)
              .borderRadius(AppSizes.RadiusMedium)
              .margin({ top: 18 })
              .onClick(() => this.loadDevices())
          } else if (this.devices.length === 0) {
            Text('这个账号还没有设备记录')
              .fontSize(14)
              .fontColor(AppColors.TextSecondary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 60 })
          } else {
            List({ space: 10 }) {
              ForEach(this.devices, (device: AccountDevice) => {
                ListItem() {
                  Row() {
                    Column() {
                      Text(device.device_name.length > 0 ? device.device_name : '未命名设备')
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(AppColors.TextPrimary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${this.deviceTypeLabel(device.device_type)}${device.device_id === this.selfId ? ' · 本机' : ''}${this.lastSeenLabel(device.last_seen_at).length > 0 ? ' · 最近登录 ' + this.lastSeenLabel(device.last_seen_at) : ''}`)
                        .fontSize(12)
                        .fontColor(AppColors.TextTertiary)
                        .margin({ top: 4 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Button('删除')
                      .height(34)
                      .fontSize(13)
                      .fontColor('#E5484D')
                      .backgroundColor('#00000000')
                      .borderRadius(8)
                      .onClick(() => this.confirmDelete(device))
                  }
                  .width('100%')
                  .padding({ left: 16, right: 8, top: 14, bottom: 14 })
                  .backgroundColor(AppColors.Surface)
                  .borderRadius(AppSizes.RadiusMedium)
                  .alignItems(VerticalAlign.Center)
                }
              }, (device: AccountDevice) => device.device_id)
            }
            .width('100%')
            .layoutWeight(1)
            .margin({ top: 16 })
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
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

      Text('我的设备')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.TextPrimary)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
        .fontSize(20)
        .fontColor([AppColors.TextSecondary])
        .onClick(() => this.loadDevices())
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 20 })
    .margin({ top: this.topSafeHeight })
    .alignItems(VerticalAlign.Center)
  }
}

@Builder
export function AccountDevicesPageBuilder() {
  AccountDevicesPage()
}
