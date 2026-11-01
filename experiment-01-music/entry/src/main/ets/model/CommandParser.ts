// Voice command model + pure-text keyword matcher for the music player.
// No ArkUI/HarmonyOS deps — safe to unit-test in a Node.js vm sandbox.

export type VoiceCommand =
  | { type: 'pause' }
  | { type: 'resume' }
  | { type: 'next' }
  | { type: 'previous' }
  | { type: 'playSong'; query: string }
  | { type: 'unknown'; raw: string };

// Order matters: longer phrases first so "我想听一首" wins over "我想听".
const PAUSE_KEYWORDS: string[] = ['暂停', '停止', '停一下', '停下', '停吧', '别播了'];
const RESUME_KEYWORDS: string[] = ['继续播放', '继续播', '继续', '恢复播放', '恢复'];
const NEXT_KEYWORDS: string[] = ['下一首', '下一曲', '后一首', '下一首歌', '换一首', '换一首歌', '切下一首', '切歌'];
const PREVIOUS_KEYWORDS: string[] = ['上一首', '上一曲', '前一首', '上一首歌', '前一首歌'];
const PLAY_PREFIXES: string[] = [
  '帮我播放', '帮我放', '帮我点',
  '我想听一首', '我想听', '我要听一首', '我要听',
  '来一首', '来首', '来一曲',
  '播放', '放首歌', '放', '点首歌', '点歌', '点播', '唱一首', '唱首'
];
// Strip these measure-word prefixes from the captured query (e.g. "一首微风" -> "微风").
const LEADING_MEASURE_WORDS: RegExp = /^(一首|一曲|这首|这首歌|那首|那首歌|首歌|那|这)/;

function normalize(text: string): string {
  return (text || '').trim().replace(/\s+/g, '');
}

function containsAny(haystack: string, phrases: string[]): boolean {
  for (const phrase of phrases) {
    if (haystack.includes(phrase)) {
      return true;
    }
  }
  return false;
}

function cleanQuery(query: string): string {
  const stripped = query.replace(LEADING_MEASURE_WORDS, '').trim();
  // Strip trailing filler particles so "微风吧" -> "微风".
  return stripped.replace(/[吧呢啊呀哦]+$/, '').trim();
}

// parseCommand maps free-form Mandarin speech text to a structured VoiceCommand.
// Precedence: pause > resume > next > previous > playSong > unknown.
// A bare "播放" or "放" without a song name is treated as resume (toggle play).
export function parseCommand(text: string): VoiceCommand {
  const raw: string = text || '';
  const normalized: string = normalize(raw);
  if (!normalized) {
    return { type: 'unknown', raw };
  }
  // A lone "停" always means pause; the multi-char variants are checked below.
  if (normalized === '停' || containsAny(normalized, PAUSE_KEYWORDS)) {
    return { type: 'pause' };
  }
  if (containsAny(normalized, RESUME_KEYWORDS)) {
    return { type: 'resume' };
  }
  if (containsAny(normalized, NEXT_KEYWORDS)) {
    return { type: 'next' };
  }
  if (containsAny(normalized, PREVIOUS_KEYWORDS)) {
    return { type: 'previous' };
  }
  for (const prefix of PLAY_PREFIXES) {
    if (normalized.startsWith(prefix)) {
      const query: string = cleanQuery(normalized.substring(prefix.length));
      if (query.length > 0) {
        return { type: 'playSong', query };
      }
      // Bare "播放"/"放"/"点歌" with no song name: treat as resume (toggle to play).
      return { type: 'resume' };
    }
  }
  return { type: 'unknown', raw };
}
