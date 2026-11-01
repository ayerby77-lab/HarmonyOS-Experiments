/**
 * 相机运行时权限助手。
 *
 * - ensureCameraPermission：先查询已授权状态，未授权时弹系统授权框；
 *   区分“弹框后被拒绝”（可再次请求）与“未弹框直接拒绝”（需引导去系统设置）。
 * - openCameraSettings：跳转系统设置中本应用详情页，供用户手动开启相机权限。
 */
import { abilityAccessCtrl, bundleManager, common, Want, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CameraPermission';
const DOMAIN: number = 0x0000;

const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA';

export enum CameraPermissionResult {
  /** 已授权。 */
  GRANTED = 'granted',
  /** 弹框后被用户拒绝，可再次发起请求。 */
  DENIED = 'denied',
  /** 系统未弹框直接拒绝（用户曾勾选不再询问或策略限制），需引导到系统设置。 */
  DENIED_WITHOUT_DIALOG = 'denied_without_dialog'
}

/** 查询当前是否已持有相机权限。 */
export function hasCameraPermission(): boolean {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const status = atManager.checkAccessTokenSync(bundleInfo.appInfo.accessTokenId, CAMERA_PERMISSION);
    return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'checkAccessTokenSync failed: %{public}s', JSON.stringify(e));
    return false;
  }
}

/**
 * 确保相机权限：已授权直接返回；否则发起系统授权请求。
 * 需要 UIAbilityContext 才能弹授权框。
 */
export async function ensureCameraPermission(context: common.UIAbilityContext): Promise<CameraPermissionResult> {
  if (hasCameraPermission()) {
    return CameraPermissionResult.GRANTED;
  }
  const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  try {
    const result = await atManager.requestPermissionsFromUser(context, [CAMERA_PERMISSION]);
    if (result.authResults.length > 0 && result.authResults[0] === 0) {
      return CameraPermissionResult.GRANTED;
    }
    const dialogShown: boolean = result.dialogShownResults !== undefined &&
      result.dialogShownResults.length > 0 ? result.dialogShownResults[0] : true;
    hilog.info(DOMAIN, TAG, 'Camera permission denied, dialogShown=%{public}s', `${dialogShown}`);
    return dialogShown ? CameraPermissionResult.DENIED : CameraPermissionResult.DENIED_WITHOUT_DIALOG;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed: %{public}s', JSON.stringify(e));
    return CameraPermissionResult.DENIED;
  }
}

/** 打开系统设置中本应用的详情页，供用户手动开启相机权限。 */
export async function openCameraSettings(context: common.UIAbilityContext): Promise<void> {
  const bundleInfo = bundleManager.getBundleInfoForSelfSync(
    bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
  const want: Want = {
    bundleName: 'com.huawei.hmos.settings',
    abilityName: 'com.huawei.hmos.settings.MainAbility',
    uri: 'application_info_entry',
    parameters: {
      pushParams: bundleInfo.name
    }
  };
  await context.startAbility(want);
}
