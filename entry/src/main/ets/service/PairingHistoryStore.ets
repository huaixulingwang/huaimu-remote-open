/*
 * 配对记录（只读历史）
 *
 * 退出账号时，从账号名单同步进来、并且曾经配对过的电脑会从首页移除，
 * 但保留一条历史记录，方便用户知道「这台电脑我以前配对过」。
 * 记录只用于查看，不参与连接，也不保存证书。
 */

import { PreferencesUtil } from '../utils/PreferencesUtil';
import { Logger } from '../common/Logger';

const TAG: string = 'PairingHistoryStore';
const KEY: string = 'lingwang.pairing_history';
const MAX_RECORDS: number = 50;

/** 一条配对历史记录 */
export interface PairingRecord {
  uuid: string;
  name: string;
  address: string;
  pairedAt: number;
  /** 是否真正完成过配对；退出时还没配上也会留记录，用这个字段区分 */
  paired: boolean;
}

export class PairingHistoryStore {
  /** 读取全部记录（新的在前） */
  static async list(): Promise<PairingRecord[]> {
    try {
      const raw: string = await PreferencesUtil.get<string>(KEY, '');
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as PairingRecord[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (err) {
      Logger.warn(TAG, `读取配对记录失败: ${(err as Error).message}`);
      return [];
    }
  }

  /** 新增或更新一条记录（同一台电脑只留最新一条） */
  static async add(record: PairingRecord): Promise<void> {
    try {
      const records: PairingRecord[] = await PairingHistoryStore.list();
      const kept: PairingRecord[] = records.filter((item: PairingRecord) => item.uuid !== record.uuid);
      kept.unshift(record);
      const trimmed: PairingRecord[] = kept.slice(0, MAX_RECORDS);
      await PreferencesUtil.put(KEY, JSON.stringify(trimmed));
    } catch (err) {
      Logger.warn(TAG, `保存配对记录失败: ${(err as Error).message}`);
    }
  }
}
