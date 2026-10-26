/*
 * 配对记录（只读）
 *
 * 退出账号时，从账号名单同步进来、并且配对过的电脑会从首页移除，
 * 这里保留一条历史记录。只用于查看，不能从这里连接电脑。
 */

import { AppNav } from '../common/AppNav';
import { AppColors, AppSizes } from '../common/Theme';
import { PairingHistoryStore, PairingRecord } from '../service/PairingHistoryStore';
import { Logger } from '../common/Logger';

const TAG: string = 'PairingRecordsPage';

@Component
struct PairingRecordsPage {
  @StorageProp('topSafeHeight') topSafeHeight: number = 56;

  @State records: PairingRecord[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.loadRecords();
  }

  private async loadRecords(): Promise<void> {
    this.loading = true;
    try {
      this.records = await PairingHistoryStore.list();
    } catch (err) {
      this.records = [];
      Logger.warn(TAG, `加载配对记录失败: ${(err as Error).message}`);
    }
    this.loading = false;
  }

  private timeLabel(value: number): string {
    if (value <= 0) {
      return '';
    }
    const date = new Date(value);
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
      + `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  private subtitle(item: PairingRecord): string {
    const time: string = this.timeLabel(item.pairedAt);
    const parts: string[] = [];
    if (item.address.length > 0) {
      parts.push(item.address);
    }
    parts.push(item.paired === false ? '未完成配对' : '配对过');
    if (time.length > 0) {
      parts.push('记录于 ' + time);
    }
    return parts.join(' · ');
  }

  build() {
    NavDestination() {
      Column() {
        this.NavBar()

        Column() {
          Text('这些是从账号同步过的电脑。退出账号后它们会从首页移除，这里只留一条记录，不能直接连接。')
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
          } else if (this.records.length === 0) {
            Text('还没有配对记录')
              .fontSize(14)
              .fontColor(AppColors.TextSecondary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 60 })
          } else {
            List({ space: 10 }) {
              ForEach(this.records, (item: PairingRecord) => {
                ListItem() {
                  Column() {
                    Text(item.name.length > 0 ? item.name : '未命名电脑')
                      .fontSize(16)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(AppColors.TextPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.subtitle(item))
                      .fontSize(12)
                      .fontColor(AppColors.TextTertiary)
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                  .backgroundColor(AppColors.Surface)
                  .borderRadius(AppSizes.RadiusMedium)
                }
              }, (item: PairingRecord) => item.uuid)
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

      Text('配对记录')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.TextPrimary)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
        .fontSize(20)
        .fontColor([AppColors.TextSecondary])
        .onClick(() => this.loadRecords())
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 20 })
    .margin({ top: this.topSafeHeight })
    .alignItems(VerticalAlign.Center)
  }
}

@Builder
export function PairingRecordsPageBuilder() {
  PairingRecordsPage()
}
