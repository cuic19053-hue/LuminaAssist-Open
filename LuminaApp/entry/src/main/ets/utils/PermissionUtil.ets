/**
 * @file PermissionUtil.ets
 * @module utils
 * @description 权限申请工具。
 *
 * 封装 HarmonyOS 动态权限申请流程，避免业务层直接依赖 abilityAccessCtrl。
 */

import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { Permissions } from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';
import { Logger } from './Logger';

const TAG: string = 'PermissionUtil';

/**
 * PermissionUtil —— 权限申请工具。
 */
export class PermissionUtil {
  /**
   * 申请一组权限，返回授予成功的子集。
   *
   * @param context UIAbility Context
   * @param permissions 权限名列表
   * @returns 已授予的权限列表
   */
  public static async requestPermissions(
    context: Context,
    permissions: Array<Permissions>
  ): Promise<Array<Permissions>> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const granted: Array<Permissions> = [];

    try {
      const result = await atManager.requestPermissionsFromUser(context, permissions);
      for (let i = 0; i < result.permissions.length; i += 1) {
        // requestPermissionsFromUser 返回的 permissions 为 Array<string>，
        // 此处重新断言为 Permissions 联合类型（调用方传入时已按 Permissions 约束）。
        const perm: string = result.permissions[i];
        const status: number = result.authResults[i];
        if (status === 0) {
          granted.push(perm as Permissions);
          Logger.info(TAG, `权限已授予: ${perm}`);
        } else {
          Logger.warn(TAG, `权限被拒绝: ${perm}`);
        }
      }
    } catch (error) {
      Logger.error(TAG, `权限申请异常: ${JSON.stringify(error)}`);
    }
    return granted;
  }

  /**
   * 检查权限是否已授予。
   */
  public static async hasPermission(permission: Permissions): Promise<boolean> {
    try {
      const bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = bundleInfo.appInfo.accessTokenId;
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const grantStatus: abilityAccessCtrl.GrantStatus = await atManager.checkAccessToken(tokenId, permission);
      return grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      Logger.error(TAG, `权限检查异常: ${JSON.stringify(error)}`);
      return false;
    }
  }
}