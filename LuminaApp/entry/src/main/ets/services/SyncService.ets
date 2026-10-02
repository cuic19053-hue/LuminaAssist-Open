import connection from '@ohos.net.connection';
import { DatabaseUtil } from '../utils/DatabaseUtil';
import { HttpClient } from './HttpClient';
import { Logger } from '../utils/Logger';

const TAG: string = 'SyncService';

export class SyncService {
  private static instance: SyncService | null = null;
  private netConnection: connection.NetConnection | null = null;
  private isSyncing: boolean = false;

  private constructor() {}

  public static getInstance(): SyncService {
    if (SyncService.instance === null) {
      SyncService.instance = new SyncService();
    }
    return SyncService.instance;
  }

  public registerNetworkObserver(): void {
    if (this.netConnection) return;
    
    this.netConnection = connection.createNetConnection();
    
    this.netConnection.on('netAvailable', (netHandle: connection.NetHandle) => {
      Logger.info(TAG, 'Network available. Triggering background sync...');
      this.triggerSync();
    });
    
    this.netConnection.register((err) => {
      if (err) {
        Logger.error(TAG, `Failed to register network observer: ${JSON.stringify(err)}`);
      } else {
        Logger.info(TAG, 'Network observer registered successfully.');
      }
    });
  }

  public async triggerSync(): Promise<void> {
    if (this.isSyncing) return;
    this.isSyncing = true;
    
    try {
      const db = DatabaseUtil.getInstance();
      
      const unsyncedChats = await db.getUnsyncedChatLogs();
      const unsyncedActions = await db.getUnsyncedActionLogs();
      
      if (unsyncedChats.length === 0 && unsyncedActions.length === 0) {
        this.isSyncing = false;
        return;
      }
      
      Logger.info(TAG, `Found ${unsyncedChats.length} chats and ${unsyncedActions.length} actions to sync.`);
      
      const payload = {
        'chat_logs': unsyncedChats,
        'action_logs': unsyncedActions
      };
      
      const response = await HttpClient.getInstance().post('/api/v1/sync/push', payload) as Record<string, Object>;
      
      if (response['success'] === true) {
        // Mark as synced
        if (unsyncedChats.length > 0) {
          const chatIds = unsyncedChats.map(c => String(c['local_id']));
          await db.markChatLogsSynced(chatIds);
        }
        
        if (unsyncedActions.length > 0) {
          const actionIds = unsyncedActions.map(a => String(a['local_id']));
          await db.markActionLogsSynced(actionIds);
        }
        
        Logger.info(TAG, 'Push successful, updated sync_status to 1.');
      }
      
    } catch (err) {
      Logger.error(TAG, `Sync failed: ${err}`);
    } finally {
      this.isSyncing = false;
    }
  }
}
