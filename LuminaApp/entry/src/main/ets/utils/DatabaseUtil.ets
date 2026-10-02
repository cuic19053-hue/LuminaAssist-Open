import relationalStore from '@ohos.data.relationalStore';
import util from '@ohos.util';
import { Logger } from './Logger';

const TAG: string = 'DatabaseUtil';
const DB_NAME: string = 'LuminaDB.db';

export interface EmergencyMedItem {
  name: string;
  category: string;
  usage: string;
  fatalWarning: string;
}

export class DatabaseUtil {
  private static instance: DatabaseUtil | null = null;
  private rdbStore: relationalStore.RdbStore | null = null;

  private constructor() {}

  public static getInstance(): DatabaseUtil {
    if (DatabaseUtil.instance === null) {
      DatabaseUtil.instance = new DatabaseUtil();
    }
    return DatabaseUtil.instance;
  }

  public async init(context: Context): Promise<void> {
    if (this.rdbStore !== null) {
      return;
    }
    
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    try {
      this.rdbStore = await relationalStore.getRdbStore(context, config);
      await this.createTables();
      await this.seedMedicineKb();
      Logger.info(TAG, 'RdbStore initialized successfully.');
    } catch (err) {
      Logger.error(TAG, `Failed to init RdbStore: ${err}`);
    }
  }

  private async createTables(): Promise<void> {
    if (!this.rdbStore) return;
    
    const createChatLogsSql = `
      CREATE TABLE IF NOT EXISTS chat_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        sync_status INTEGER DEFAULT 0
      )
    `;
    
    const createActionLogsSql = `
      CREATE TABLE IF NOT EXISTS action_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT NOT NULL,
        action_type TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        sync_status INTEGER DEFAULT 0
      )
    `;
    
    const createMedicineKbSql = `
      CREATE TABLE IF NOT EXISTS medicine_kb (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        usage TEXT NOT NULL,
        fatalWarning TEXT NOT NULL
      )
    `;
    
    await this.rdbStore.executeSql(createChatLogsSql);
    await this.rdbStore.executeSql(createActionLogsSql);
    await this.rdbStore.executeSql(createMedicineKbSql);
  }

  // --- Medicine KB ---

  private async seedMedicineKb(): Promise<void> {
    if (!this.rdbStore) return;
    const predicates = new relationalStore.RdbPredicates('medicine_kb');
    const countResultSet = await this.rdbStore.query(predicates);
    if (countResultSet.rowCount > 0) {
      countResultSet.close();
      return; // Already seeded
    }
    countResultSet.close();

    interface EmergencyMedItem {
      name: string;
      category: string;
      usage: string;
      fatalWarning: string;
    }

    const med1: EmergencyMedItem = { name: '硝酸甘油片', category: '心绞痛急救药', usage: '发作时必须舌下含服，建议坐着含服以防血压骤降跌倒。', fatalWarning: '绝对不可以吞下！' };
    const med2: EmergencyMedItem = { name: '速效救心丸', category: '急救用药', usage: '心绞痛急性发作时，立刻舌下含服10到15粒。平时按医生吩咐吞服即可。', fatalWarning: '发作时请务必舌下含服，切勿直接吞下。' };
    const emergencyMeds: Array<EmergencyMedItem> = [med1, med2];

    for (const med of emergencyMeds) {
      const valueBucket: relationalStore.ValuesBucket = {
        'name': med.name,
        'category': med.category,
        'usage': med.usage,
        'fatalWarning': med.fatalWarning
      };
      await this.rdbStore.insert('medicine_kb', valueBucket);
    }
    Logger.info(TAG, 'Seeded emergency medicine KB.');
  }

  public async queryMedicine(keyword: string): Promise<Record<string, Object> | null> {
    if (!this.rdbStore) return null;
    const predicates = new relationalStore.RdbPredicates('medicine_kb');
    predicates.like('name', `%${keyword}%`);
    const resultSet = await this.rdbStore.query(predicates);
    
    let result: Record<string, Object> | null = null;
    if (resultSet.goToNextRow()) {
      const resRecord: EmergencyMedItem = {
        name: resultSet.getString(resultSet.getColumnIndex('name')),
        category: resultSet.getString(resultSet.getColumnIndex('category')),
        usage: resultSet.getString(resultSet.getColumnIndex('usage')),
        fatalWarning: resultSet.getString(resultSet.getColumnIndex('fatalWarning'))
      };
      const obj: Record<string, Object> = {
        'name': resRecord.name,
        'category': resRecord.category,
        'usage': resRecord.usage,
        'fatalWarning': resRecord.fatalWarning
      };
      result = obj;
    }
    resultSet.close();
    return result;
  }

  // --- Chat Logs ---
  
  public async insertChatLog(role: string, content: string): Promise<void> {
    if (!this.rdbStore) return;
    const localId = util.generateRandomUUID();
    const ts = Date.now();
    
    const valueBucket: relationalStore.ValuesBucket = {
      'local_id': localId,
      'role': role,
      'content': content,
      'timestamp': ts,
      'sync_status': 0
    };
    await this.rdbStore.insert('chat_logs', valueBucket);
  }

  public async getUnsyncedChatLogs(): Promise<Array<Record<string, Object>>> {
    if (!this.rdbStore) return [];
    
    const predicates = new relationalStore.RdbPredicates('chat_logs');
    predicates.equalTo('sync_status', 0);
    
    const resultSet = await this.rdbStore.query(predicates);
    const results: Array<Record<string, Object>> = [];
    
    while (resultSet.goToNextRow()) {
      results.push({
        'local_id': resultSet.getString(resultSet.getColumnIndex('local_id')),
        'role': resultSet.getString(resultSet.getColumnIndex('role')),
        'content': resultSet.getString(resultSet.getColumnIndex('content')),
        'timestamp': resultSet.getLong(resultSet.getColumnIndex('timestamp'))
      });
    }
    resultSet.close();
    return results;
  }

  public async markChatLogsSynced(localIds: Array<string>): Promise<void> {
    if (!this.rdbStore || localIds.length === 0) return;
    
    const valueBucket: relationalStore.ValuesBucket = { 'sync_status': 1 };
    const predicates = new relationalStore.RdbPredicates('chat_logs');
    predicates.in('local_id', localIds);
    await this.rdbStore.update(valueBucket, predicates);
  }

  // --- Action Logs ---
  
  public async insertActionLog(actionType: string, actionDetail: string): Promise<void> {
    if (!this.rdbStore) return;
    const localId = util.generateRandomUUID();
    const ts = Date.now();
    
    const valueBucket: relationalStore.ValuesBucket = {
      'local_id': localId,
      'action_type': actionType,
      'action_detail': actionDetail,
      'timestamp': ts,
      'sync_status': 0
    };
    await this.rdbStore.insert('action_logs', valueBucket);
  }

  public async getUnsyncedActionLogs(): Promise<Array<Record<string, Object>>> {
    if (!this.rdbStore) return [];
    
    const predicates = new relationalStore.RdbPredicates('action_logs');
    predicates.equalTo('sync_status', 0);
    
    const resultSet = await this.rdbStore.query(predicates);
    const results: Array<Record<string, Object>> = [];
    
    while (resultSet.goToNextRow()) {
      results.push({
        'local_id': resultSet.getString(resultSet.getColumnIndex('local_id')),
        'action_type': resultSet.getString(resultSet.getColumnIndex('action_type')),
        'action_detail': resultSet.getString(resultSet.getColumnIndex('action_detail')),
        'timestamp': resultSet.getLong(resultSet.getColumnIndex('timestamp'))
      });
    }
    resultSet.close();
    return results;
  }

  public async markActionLogsSynced(localIds: Array<string>): Promise<void> {
    if (!this.rdbStore || localIds.length === 0) return;
    
    const valueBucket: relationalStore.ValuesBucket = { 'sync_status': 1 };
    const predicates = new relationalStore.RdbPredicates('action_logs');
    predicates.in('local_id', localIds);
    await this.rdbStore.update(valueBucket, predicates);
  }
}
