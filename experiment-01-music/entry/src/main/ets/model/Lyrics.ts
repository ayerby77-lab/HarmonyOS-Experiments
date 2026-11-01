export interface LyricGlyph {
  text: string;
  start: number;
  end: number;
}

export interface LyricLine {
  start: number;
  end: number;
  text: string;
  glyphs: LyricGlyph[];
  precise: boolean;
}

interface Segment {
  start: number;
  text: string;
  tagged: boolean;
}

interface PendingLine {
  start: number;
  order: number;
  segments: Segment[];
}

function timestamp(value: string): number {
  if (!/^\d+:\d{2}(?:\.\d{1,3})?$/.test(value)) return -1;
  const parts = value.split(':');
  const seconds = Number(parts[1]);
  if (seconds >= 60) return -1;
  const time = Number(parts[0]) * 60000 + Math.round(seconds * 1000);
  return Number.isFinite(time) ? time : -1;
}

function segmentsOf(text: string, start: number): Segment[] {
  text = text.replace(/<[^>]*>/g, (tag: string): string => {
    return timestamp(tag.substring(1, tag.length - 1)) >= 0 ? tag : '';
  });
  const segments: Segment[] = [];
  const tags = text.match(/<[^>]*>/g) || [];
  let cursor = 0;
  let time = start;
  let tagged = false;
  for (const tag of tags) {
    const index = text.indexOf(tag, cursor);
    const words = text.substring(cursor, index);
    if (words.length > 0) segments.push({ start: time, text: words, tagged: tagged });
    const parsed = timestamp(tag.substring(1, tag.length - 1));
    if (parsed >= 0) {
      time = Math.max(time, parsed);
      tagged = true;
    }
    cursor = index + tag.length;
  }
  // An empty trailing tag still marks the end of the previous sung segment.
  segments.push({ start: time, text: text.substring(cursor), tagged: tagged });
  return segments;
}

/** All times are milliseconds. A positive global [offset:N] delays lyrics by N ms. */
export function parseLrc(source: string, durationMs: number): LyricLine[] {
  let offset = 0;
  const offsets = source.match(/\[offset:[+-]?\d+\]/gi) || [];
  for (const tag of offsets) {
    const value = Number(tag.substring(8, tag.length - 1));
    if (Number.isFinite(value)) offset = value;
  }
  const pending: PendingLine[] = [];
  for (const raw of source.replace(/\r/g, '').split('\n')) {
    const tags = raw.match(/\[[^\]]*\]/g) || [];
    const stamps: number[] = [];
    for (const tag of tags) {
      const value = timestamp(tag.substring(1, tag.length - 1));
      if (value >= 0) stamps.push(value);
    }
    if (stamps.length === 0) continue;
    const body = raw.replace(/\[[^\]]*\]/g, '').trim();
    const segments = segmentsOf(body, stamps[0]);
    for (const stamp of stamps) {
      const shifted: Segment[] = [];
      for (const segment of segments) {
        shifted.push({ start: Math.max(0, segment.start + stamp - stamps[0] + offset),
          text: segment.text, tagged: segment.tagged });
      }
      pending.push({ start: Math.max(0, stamp + offset), order: pending.length, segments: shifted });
    }
  }
  pending.sort((a: PendingLine, b: PendingLine): number => a.start - b.start || a.order - b.order);
  const lines: LyricLine[] = [];
  const duration = Number.isFinite(durationMs) && durationMs > 0 ? durationMs : 0;
  for (let i = 0; i < pending.length; i++) {
    const item = pending[i];
    let end = duration > 0 ? Math.max(item.start, duration) : item.start + 5000;
    for (let j = i + 1; j < pending.length; j++) {
      if (pending[j].start > item.start) {
        end = duration > 0 ? Math.max(item.start, Math.min(duration, pending[j].start)) : pending[j].start;
        break;
      }
    }
    const line: LyricLine = { start: item.start, end: end, text: '', glyphs: [], precise: true };
    for (let k = 0; k < item.segments.length; k++) {
      const segment = item.segments[k];
      const chars = Array.from(segment.text);
      const start = Math.min(end, Math.max(item.start, segment.start));
      const finish = k + 1 < item.segments.length ? Math.min(end, Math.max(start, item.segments[k + 1].start)) : end;
      if (chars.length > 0 && (!segment.tagged || chars.length !== 1)) line.precise = false;
      line.text += segment.text;
      for (let c = 0; c < chars.length; c++) {
        line.glyphs.push({ text: chars[c], start: start + (finish - start) * c / chars.length,
          end: start + (finish - start) * (c + 1) / chars.length });
      }
    }
    if (line.glyphs.length === 0) line.precise = false;
    lines.push(line);
  }
  return lines;
}

export function locateLyric(lines: LyricLine[], position: number): number {
  if (!Number.isFinite(position)) return -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (position >= lines[i].start && position < lines[i].end) return i;
  }
  return -1;
}

export function locateGlyph(line: LyricLine, position: number): number {
  if (!Number.isFinite(position)) return -1;
  for (let i = line.glyphs.length - 1; i >= 0; i--) {
    if (position >= line.glyphs[i].start && position < line.glyphs[i].end) return i;
  }
  return -1;
}
