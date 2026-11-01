/**
 * 通用 HTTP 封装（第三阶段，Agent 4）。依据 docs/phase-3-contract.md 第 1、5 节。
 *
 * - 自动附加 Bearer accessToken；
 * - HTTP 401 时用 refreshToken 刷新并重试一次（契约 §1.4）；刷新失败清空 token 抛 UNAUTHORIZED；
 * - 网络层错误与后端统一错误体（{code,message}）映射为 NetworkFailure。
 *
 * 依赖 AuthStore（单向依赖；AuthStore 自身用裸 http 调登录/刷新，无循环）。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthStore, AuthFailure } from './AuthStore';

const TAG: string = 'HttpClient';
const DOMAIN: number = 0x0000;

const DEFAULT_BASE_URL: string = 'http://127.0.0.1:8000';
const HTTP_TIMEOUT_MS: number = 10000;
/** 模型文件约 10 MB，读超时需放宽。 */
const BINARY_READ_TIMEOUT_MS: number = 120000;

export enum NetworkErrorCode {
  /** 请求未发出：断网 / DNS / 连接拒绝等。 */
  OFFLINE = 'OFFLINE',
  UNAUTHORIZED = 'UNAUTHORIZED',
  FORBIDDEN = 'FORBIDDEN',
  NOT_FOUND = 'NOT_FOUND',
  /** 4xx 业务错误（serverCode 带后端错误码）。 */
  REJECTED = 'REJECTED',
  SERVER = 'SERVER',
  INVALID_RESPONSE = 'INVALID_RESPONSE'
}

export class NetworkFailure extends Error {
  code: NetworkErrorCode;
  status: number;
  /** 后端统一错误体 code，便于与 RecognitionErrorCode/RecordErrorCode 对齐。 */
  serverCode: string;

  constructor(code: NetworkErrorCode, message: string, status: number = 0, serverCode: string = '') {
    super(message);
    this.code = code;
    this.status = status;
    this.serverCode = serverCode;
  }
}

/** 后端统一错误体。 */
interface ErrorBody {
  code?: string;
  message?: string;
}

export class HttpClient {
  private static instance: HttpClient | null = null;

  static getInstance(): HttpClient {
    if (HttpClient.instance === null) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  private baseUrl: string = DEFAULT_BASE_URL;
  private refreshing: Promise<void> | null = null;

  private constructor() {
  }

  setBaseUrl(baseUrl: string): void {
    this.baseUrl = baseUrl;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  /** POST JSON，默认附带鉴权。 */
  async post<T>(path: string, body: object, authenticated: boolean = true): Promise<T> {
    return this.request<T>(http.RequestMethod.POST, path, body, authenticated);
  }

  /** GET，默认附带鉴权。 */
  async get<T>(path: string, authenticated: boolean = true): Promise<T> {
    return this.request<T>(http.RequestMethod.GET, path, null, authenticated);
  }

  /**
   * GET 二进制响应（模型文件下载）。401 时同样刷新并重试一次。
   * @param onProgress 下载进度 0..1；拿不到总长度时仅在完成时回调 1。
   * @throws NetworkFailure
   */
  async getBinary(path: string, onProgress?: (fraction: number) => void): Promise<ArrayBuffer> {
    try {
      return await this.doBinaryRequest(path, onProgress);
    } catch (e) {
      if (e instanceof NetworkFailure && e.code === NetworkErrorCode.UNAUTHORIZED) {
        await this.refreshOnce();
        return this.doBinaryRequest(path, onProgress);
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  private async doBinaryRequest(path: string, onProgress?: (fraction: number) => void): Promise<ArrayBuffer> {
    const header: Record<string, string> = {};
    const token: string = AuthStore.getInstance().getAccessToken();
    if (token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      if (onProgress !== undefined) {
        req.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
          if (data.totalSize > 0) {
            onProgress(Math.min(1, data.receiveSize / data.totalSize));
          }
        });
      }
      const resp: http.HttpResponse = await req.request(this.baseUrl + path, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: BINARY_READ_TIMEOUT_MS
      });
      const status: number = resp.responseCode;
      if (status >= 200 && status < 300) {
        const body: ArrayBuffer = resp.result as ArrayBuffer;
        if (onProgress !== undefined) {
          onProgress(1);
        }
        return body;
      }
      if (status === 401) {
        throw new NetworkFailure(NetworkErrorCode.UNAUTHORIZED, '登录已过期', status);
      }
      if (status === 403) {
        throw new NetworkFailure(NetworkErrorCode.FORBIDDEN, '无权访问该资源', status);
      }
      if (status === 404) {
        throw new NetworkFailure(NetworkErrorCode.NOT_FOUND, '资源不存在', status);
      }
      if (status >= 500) {
        throw new NetworkFailure(NetworkErrorCode.SERVER, `HTTP ${status}`, status);
      }
      throw new NetworkFailure(NetworkErrorCode.REJECTED, `HTTP ${status}`, status);
    } catch (e) {
      if (e instanceof NetworkFailure) {
        throw e;
      }
      hilog.warn(DOMAIN, TAG, 'binary request %{public}s failed: %{public}s', path, JSON.stringify(e));
      throw new NetworkFailure(NetworkErrorCode.OFFLINE, `网络不可用: ${JSON.stringify(e)}`);
    } finally {
      req.off('dataReceiveProgress');
      req.destroy();
    }
  }

  /**
   * 通用请求。401 时刷新 token 并重试一次；refresh 并发去重。
   * @throws NetworkFailure
   */
  async request<T>(method: http.RequestMethod, path: string, body: object | null,
    authenticated: boolean): Promise<T> {
    try {
      return await this.doRequest<T>(method, path, body, authenticated);
    } catch (e) {
      if (e instanceof NetworkFailure && e.code === NetworkErrorCode.UNAUTHORIZED && authenticated) {
        // 契约 §1.4：401 → refresh 后重试一次；refresh 失败 → 清空 token，UI 提示重新授权。
        await this.refreshOnce();
        return this.doRequest<T>(method, path, body, authenticated);
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(String(e));
    }
  }

  private async refreshOnce(): Promise<void> {
    if (this.refreshing === null) {
      const auth: AuthStore = AuthStore.getInstance();
      this.refreshing = auth.refresh(this.baseUrl)
        .catch((e: Error) => {
          auth.clearTokens();
          throw new NetworkFailure(NetworkErrorCode.UNAUTHORIZED,
            `登录已过期，需要重新授权: ${e.message}`, 401,
            e instanceof AuthFailure ? e.serverCode : '');
        })
        .finally(() => {
          this.refreshing = null;
        });
    }
    return this.refreshing;
  }

  private async doRequest<T>(method: http.RequestMethod, path: string, body: object | null,
    authenticated: boolean): Promise<T> {
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    if (authenticated) {
      const token: string = AuthStore.getInstance().getAccessToken();
      if (token.length > 0) {
        header['Authorization'] = `Bearer ${token}`;
      }
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(this.baseUrl + path, {
        method: method,
        header: header,
        extraData: body === null ? '' : JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      return this.parseResponse<T>(resp, path);
    } catch (e) {
      if (e instanceof NetworkFailure) {
        throw e;
      }
      hilog.warn(DOMAIN, TAG, 'request %{public}s failed: %{public}s', path, JSON.stringify(e));
      throw new NetworkFailure(NetworkErrorCode.OFFLINE, `网络不可用: ${JSON.stringify(e)}`);
    } finally {
      req.destroy();
    }
  }

  private parseResponse<T>(resp: http.HttpResponse, path: string): T {
    const text: string = resp.result as string;
    const status: number = resp.responseCode;
    if (status >= 200 && status < 300) {
      try {
        return JSON.parse(text) as T;
      } catch (e) {
        throw new NetworkFailure(NetworkErrorCode.INVALID_RESPONSE,
          `响应不是合法 JSON: ${path}`, status);
      }
    }
    let serverCode: string = '';
    let message: string = `HTTP ${status}`;
    try {
      const err: ErrorBody = JSON.parse(text) as ErrorBody;
      serverCode = err.code ?? '';
      message = err.message ?? message;
    } catch (e) {
      // 非 JSON 错误体。
    }
    if (status === 401) {
      throw new NetworkFailure(NetworkErrorCode.UNAUTHORIZED, message, status, serverCode);
    }
    if (status === 403) {
      throw new NetworkFailure(NetworkErrorCode.FORBIDDEN, message, status, serverCode);
    }
    if (status === 404) {
      throw new NetworkFailure(NetworkErrorCode.NOT_FOUND, message, status, serverCode);
    }
    if (status >= 500) {
      throw new NetworkFailure(NetworkErrorCode.SERVER, message, status, serverCode);
    }
    throw new NetworkFailure(NetworkErrorCode.REJECTED, message, status, serverCode);
  }
}
