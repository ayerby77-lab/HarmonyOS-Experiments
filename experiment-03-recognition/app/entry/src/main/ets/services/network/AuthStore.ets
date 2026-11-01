/**
 * 鉴权令牌存储（第三阶段，Agent 4）。依据 docs/phase-3-contract.md 第 1 节。
 *
 * 职责：
 * - deviceId 首次启动生成（UUID）并持久化到 Preferences；
 * - accessToken / refreshToken / expiresAtMs 持久化（Preferences，密钥不进 RDB）；
 * - login / refresh 直接调用后端 /api/auth/*（不经过 HttpClient，避免循环依赖）。
 *
 * 注意：clientKey 为客户端内嵌密钥，生产构建应由 build profile 注入（契约第 6 节），
 * 当前为开发默认值，与 backend/app/core/config.py 的 DEVICE_SECRET 默认值一致。
 */
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'AuthStore';
const DOMAIN: number = 0x0000;

const PREF_NAME: string = 'sync_auth';
const KEY_DEVICE_ID: string = 'deviceId';
const KEY_ACCESS_TOKEN: string = 'accessToken';
const KEY_REFRESH_TOKEN: string = 'refreshToken';
const KEY_EXPIRES_AT_MS: string = 'expiresAtMs';

/** 开发用内嵌密钥；与 backend DEVICE_SECRET 默认一致，生产构建替换（契约 §6）。 */
export const DEV_CLIENT_KEY: string = 'dev-device-secret-change-me';

/** access token 剩余有效期不足该值时视为临期，主动刷新。 */
const EXPIRY_SKEW_MS: number = 60 * 1000;
const HTTP_TIMEOUT_MS: number = 10000;

/** 鉴权失败（登录拒绝 / refresh 失效），调用方应提示重新授权。 */
export class AuthFailure extends Error {
  status: number;
  serverCode: string;

  constructor(message: string, status: number, serverCode: string = '') {
    super(message);
    this.status = status;
    this.serverCode = serverCode;
  }
}

/** POST /api/auth/login | refresh 的响应体。 */
interface TokenResponseBody {
  accessToken: string;
  refreshToken: string;
  tokenType: string;
  expiresIn: number;
  refreshExpiresIn: number;
}

/** 后端统一错误体。 */
interface ErrorBody {
  code?: string;
  message?: string;
}

/** POST /api/auth/login 请求体。 */
interface LoginRequestBody {
  deviceId: string;
  deviceSecret: string;
}

/** POST /api/auth/refresh 请求体。 */
interface RefreshRequestBody {
  refreshToken: string;
}

export class AuthStore {
  private static instance: AuthStore | null = null;

  static getInstance(): AuthStore {
    if (AuthStore.instance === null) {
      AuthStore.instance = new AuthStore();
    }
    return AuthStore.instance;
  }

  private pref: preferences.Preferences | null = null;
  private context: common.Context | null = null;
  private initPromise: Promise<boolean> | null = null;
  /** 并发 ensureValidToken 合并用。 */
  private ensureInFlight: Promise<void> | null = null;

  // 内存缓存，避免每次请求都读 Preferences。
  private accessToken: string = '';
  private refreshToken: string = '';
  private expiresAtMs: number = 0;

  private constructor() {
  }

  /** 幂等初始化；加载已持久化的 token。 */
  async initialize(context?: common.Context): Promise<boolean> {
    if (context !== undefined) {
      this.context = context;
    }
    if (this.pref !== null) {
      return true;
    }
    if (this.initPromise === null) {
      this.initPromise = this.doInitialize();
    }
    const ok: boolean = await this.initPromise;
    if (!ok) {
      this.initPromise = null;
    }
    return ok;
  }

  private async doInitialize(): Promise<boolean> {
    try {
      const context: common.Context = this.resolveContext();
      this.pref = preferences.getPreferencesSync(context, { name: PREF_NAME });
      this.accessToken = this.pref.getSync(KEY_ACCESS_TOKEN, '') as string;
      this.refreshToken = this.pref.getSync(KEY_REFRESH_TOKEN, '') as string;
      this.expiresAtMs = this.pref.getSync(KEY_EXPIRES_AT_MS, 0) as number;
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
      this.pref = null;
      return false;
    }
  }

  private resolveContext(): common.Context {
    if (this.context !== null) {
      return this.context;
    }
    const context: common.Context = getContext() as common.Context;
    this.context = context;
    return context;
  }

  /** 设备标识：首次生成 UUID 并持久化。 */
  getDeviceId(): string {
    const pref: preferences.Preferences = this.ensurePref();
    let deviceId: string = pref.getSync(KEY_DEVICE_ID, '') as string;
    if (deviceId.length === 0) {
      deviceId = util.generateRandomUUID(false);
      pref.putSync(KEY_DEVICE_ID, deviceId);
      pref.flush();
      hilog.info(DOMAIN, TAG, 'deviceId generated');
    }
    return deviceId;
  }

  getAccessToken(): string {
    return this.accessToken;
  }

  hasToken(): boolean {
    return this.accessToken.length > 0;
  }

  /** access token 不存在或临期。 */
  isExpiringSoon(): boolean {
    return this.accessToken.length === 0 || Date.now() + EXPIRY_SKEW_MS >= this.expiresAtMs;
  }

  /** 清空 token（refresh 失效 / 设备被停用）。 */
  clearTokens(): void {
    this.accessToken = '';
    this.refreshToken = '';
    this.expiresAtMs = 0;
    if (this.pref !== null) {
      this.pref.deleteSync(KEY_ACCESS_TOKEN);
      this.pref.deleteSync(KEY_REFRESH_TOKEN);
      this.pref.deleteSync(KEY_EXPIRES_AT_MS);
      this.pref.flush();
    }
  }

  /**
   * 设备登录：deviceId + clientKey 换 token pair。首次接入时后端自动登记设备。
   * @throws AuthFailure 密钥无效 / 设备停用 / 网络错误
   */
  async login(baseUrl: string, clientKey: string): Promise<void> {
    await this.initialize();
    const deviceId: string = this.getDeviceId();
    const body: LoginRequestBody = { deviceId: deviceId, deviceSecret: clientKey };
    const token: TokenResponseBody = await this.postToken(baseUrl, '/api/auth/login', body);
    this.saveTokens(token);
    hilog.info(DOMAIN, TAG, 'login ok, expiresIn=%{public}ds', token.expiresIn);
  }

  /**
   * 用 refreshToken 换新 token pair（后端轮换 refresh token）。
   * 失败时清空本地 token，调用方需重新 login。
   * @throws AuthFailure
   */
  async refresh(baseUrl: string): Promise<void> {
    await this.initialize();
    if (this.refreshToken.length === 0) {
      throw new AuthFailure('无 refreshToken，需要重新登录', 401);
    }
    const body: RefreshRequestBody = { refreshToken: this.refreshToken };
    try {
      const token: TokenResponseBody = await this.postToken(baseUrl, '/api/auth/refresh', body);
      this.saveTokens(token);
      hilog.info(DOMAIN, TAG, 'refresh ok');
    } catch (e) {
      this.clearTokens();
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  /** 确保有可用 token：无 token 登录、临期刷新。并发调用合并，避免重复登录。 */
  async ensureValidToken(baseUrl: string, clientKey: string): Promise<void> {
    if (this.ensureInFlight === null) {
      this.ensureInFlight = this.doEnsureValidToken(baseUrl, clientKey).finally(() => {
        this.ensureInFlight = null;
      });
    }
    return this.ensureInFlight;
  }

  private async doEnsureValidToken(baseUrl: string, clientKey: string): Promise<void> {
    await this.initialize();
    if (!this.hasToken()) {
      await this.login(baseUrl, clientKey);
      return;
    }
    if (this.isExpiringSoon()) {
      try {
        await this.refresh(baseUrl);
      } catch (e) {
        // refresh 失效则完整重新登录一次；再失败向上抛。
        await this.login(baseUrl, clientKey);
      }
    }
  }

  private saveTokens(token: TokenResponseBody): void {
    this.accessToken = token.accessToken;
    this.refreshToken = token.refreshToken;
    this.expiresAtMs = Date.now() + token.expiresIn * 1000;
    const pref: preferences.Preferences = this.ensurePref();
    pref.putSync(KEY_ACCESS_TOKEN, this.accessToken);
    pref.putSync(KEY_REFRESH_TOKEN, this.refreshToken);
    pref.putSync(KEY_EXPIRES_AT_MS, this.expiresAtMs);
    pref.flush();
  }

  private ensurePref(): preferences.Preferences {
    if (this.pref === null) {
      // 同步兜底：initialize 未完成时直接同步创建。
      this.pref = preferences.getPreferencesSync(this.resolveContext(), { name: PREF_NAME });
    }
    return this.pref;
  }

  /** 裸 POST（不带 Bearer），解析 token 响应或抛出 AuthFailure。 */
  private async postToken(baseUrl: string, path: string, body: object): Promise<TokenResponseBody> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(baseUrl + path, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      const text: string = resp.result as string;
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        return JSON.parse(text) as TokenResponseBody;
      }
      let serverCode: string = '';
      let message: string = `HTTP ${resp.responseCode}`;
      try {
        const err: ErrorBody = JSON.parse(text) as ErrorBody;
        serverCode = err.code ?? '';
        message = err.message ?? message;
      } catch (e) {
        // 非 JSON 错误体，保留原始 message。
      }
      throw new AuthFailure(message, resp.responseCode, serverCode);
    } catch (e) {
      if (e instanceof AuthFailure) {
        throw e;
      }
      throw new AuthFailure(`网络请求失败: ${JSON.stringify(e)}`, 0);
    } finally {
      req.destroy();
    }
  }
}
