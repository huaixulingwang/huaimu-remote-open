import { AbilityStage } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

const TAG = 'EntryAbilityStage';

export default class EntryAbilityStage extends AbilityStage {
  onCreate(): void {
    Logger.info(TAG, 'AbilityStage onCreate');
  }
}
