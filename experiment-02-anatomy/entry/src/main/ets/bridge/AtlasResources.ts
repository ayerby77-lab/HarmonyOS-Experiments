// 人体浏览模块 · 本地资源路径映射（纯函数，无 ArkWeb 依赖，可独立测试）。
//
// human-atlas 构建产物在 rawfile 中的根目录。
export const ATLAS_ROOT: string = 'human-atlas/';

// 将 Web 侧发出的请求 URL 归一化为 rawfile 相对路径。
// 产物里 index.html 使用相对路径 ./assets/*、./models/atlas.json（解析为
// resource://rawfile/human-atlas/...），而模型分块使用根路径
// /models/body-N.bin.gz（解析为 resource://rawfile/models/...）；
// 两者都要映射到 ATLAS_ROOT 下，onInterceptRequest 才能命中本地文件。
export function mapRawfilePath(rawUrl: string): string {
  let url: string = rawUrl === undefined || rawUrl === null ? '' : rawUrl;
  const hashAt: number = url.indexOf('#');
  if (hashAt >= 0) {
    url = url.substring(0, hashAt);
  }
  const queryAt: number = url.indexOf('?');
  if (queryAt >= 0) {
    url = url.substring(0, queryAt);
  }

  let path: string = '';
  const scheme: string = 'resource://rawfile/';
  if (url.startsWith(scheme)) {
    path = url.substring(scheme.length);
  } else {
    const schemeAt: number = url.indexOf('://');
    if (schemeAt < 0) {
      path = url.startsWith('/') ? url.substring(1) : url;
    } else {
      const rest: string = url.substring(schemeAt + 3);
      const slashAt: number = rest.indexOf('/');
      path = slashAt < 0 ? '' : rest.substring(slashAt + 1);
    }
  }

  try {
    path = decodeURIComponent(path);
  } catch (e) {
  }

  // 归一相对写法 './x'（浏览器多数情况已解析为绝对 URL，直接输入时仍需处理）。
  while (path.startsWith('./')) {
    path = path.substring(2);
  }

  if (path.length === 0 || path.indexOf('..') >= 0) {
    return '';
  }
  if (!path.startsWith(ATLAS_ROOT)) {
    path = ATLAS_ROOT + path;
  }
  return path;
}

// 按扩展名给出响应 MIME。
export function mimeOfPath(path: string): string {
  if (path.endsWith('.html')) {
    return 'text/html';
  }
  if (path.endsWith('.js')) {
    return 'text/javascript';
  }
  if (path.endsWith('.css')) {
    return 'text/css';
  }
  if (path.endsWith('.json')) {
    return 'application/json';
  }
  if (path.endsWith('.svg')) {
    return 'image/svg+xml';
  }
  if (path.endsWith('.gz')) {
    return 'application/gzip';
  }
  return 'application/octet-stream';
}
