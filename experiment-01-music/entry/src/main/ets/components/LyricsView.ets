import { LyricLine, LyricGlyph, locateLyric, locateGlyph } from '../model/Lyrics';

// ── Centralized karaoke animation config — adjust all tuning parameters here ──
// Star appearance
const STAR_SIZE_VP: number = 24;
const STAR_REST_Y: number = 0;          // star Y offset at rest (above glyph row)
const STAR_JUMP_HEIGHT_VP: number = 12; // parabola peak height during hop

// Star motion
const HOP_MIN_MS: number = 200;
const HOP_MAX_MS: number = 500;
const HOP_STEP_MS: number = 16;         // ~60fps interpolation step

// Char impact press: star lands → glyph is pressed DOWN, then rebounds UP to rest.
const PRESS_SCALE: number = 1.12;        // scale at peak press (star impact)
const PRESS_VP: number = 5;              // downward press distance
const PRESS_DOWN_MS: number = 110;       // press-down duration (impact → compressed)
const REBOUND_MS: number = 140;          // rebound duration (compressed → rest)

// Layout
const ROW_HEIGHT: number = 44;
const STAR_GAP_VP: number = 4;
const FALLBACK_GLYPH_WIDTH_VP: number = 30;

interface StarPos { x: number; y: number; }

interface GlyphSlot {
  glyph: LyricGlyph;
  index: number;
}

@Component
export struct LyricsView {
  @Prop @Watch('onPositionChange') currentMs: number = 0;
  @Prop lines: LyricLine[] = [];
  @Prop label: string = '';
  @Prop loading: boolean = false;
  @Prop activeColor: string = '#FFFFFF';
  @Prop inactiveColor: string = 'rgba(255,255,255,0.45)';
  @Prop activeSize: number = 30;
  @Prop inactiveSize: number = 15;
  @Prop showContext: boolean = true;

  // Reactive state — only these trigger re-render; keep updates minimal for 60fps.
  @State private activeLine: number = -1;
  @State private activeGlyph: number = -1;
  @State private star: StarPos = { x: 0, y: STAR_REST_Y };
  @State private currentSlots: GlyphSlot[] = [];
  @State private bouncingGlyph: number = -1;
  @State private bouncePhase: number = 0;  // 0 = rest, 1 = up

  // Non-reactive fields — collected during layout, read by computeStarOffsetX.
  private glyphWidths: Map<number, number> = new Map<number, number>();
  private hopTimer: number = -1;
  private bounceTimer: number = -1;
  private wasReady: boolean = false;

  aboutToAppear(): void {
    this.syncGlyph(true);
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.hopTimer !== -1) { clearTimeout(this.hopTimer); this.hopTimer = -1; }
    if (this.bounceTimer !== -1) { clearTimeout(this.bounceTimer); this.bounceTimer = -1; }
  }

  private onPositionChange(): void {
    this.syncGlyph(false);
  }

  // Sync star position to AVPlayer's current time — the sole time source.
  // Early-returns when nothing changed to avoid unnecessary re-renders.
  private syncGlyph(initial: boolean): void {
    const lines: LyricLine[] = this.lines;
    const position: number = this.currentMs;
    const newLine: number = locateLyric(lines, position);
    const newGlyph: number = newLine >= 0 ? locateGlyph(lines[newLine], position) : -1;
    const lineChanged: boolean = newLine !== this.activeLine;
    const glyphChanged: boolean = newLine >= 0 ? newGlyph !== this.activeGlyph : this.activeGlyph !== -1;
    if (!initial && !lineChanged && !glyphChanged) { return; }

    // Detect a seek (jump by more than one glyph) — snap instead of animate.
    const glyphDelta: number = newGlyph - this.activeGlyph;
    const seek: boolean = Math.abs(glyphDelta) > 1;

    // Cancel any in-flight bounce when the active glyph changes.
    if (lineChanged || glyphChanged) {
      this.bouncingGlyph = -1;
      this.bouncePhase = 0;
      if (this.bounceTimer !== -1) { clearTimeout(this.bounceTimer); this.bounceTimer = -1; }
    }

    this.activeLine = newLine;
    this.activeGlyph = newGlyph;

    if (lineChanged) {
      // Rebuild slots for the new line and reset layout measurements.
      this.glyphWidths.clear();
      this.currentSlots = this.collectSlots(newLine);
      this.wasReady = false;
    }

    if (newLine < 0 || newGlyph < 0) {
      // No active lyric — park the star above the row.
      this.star = { x: this.star.x, y: STAR_REST_Y - 40 };
      this.wasReady = false;
      return;
    }

    const targetX: number = this.computeStarOffsetX(newGlyph);
    if (!this.wasReady || initial || seek || lineChanged) {
      // Snap to the target without animation (first appear, seek, or line change).
      this.star = { x: targetX, y: STAR_REST_Y };
      this.wasReady = true;
      this.triggerBounce(newGlyph);
      return;
    }

    // Normal progression — parabolic hop to the next glyph.
    this.hopTo(targetX, newGlyph);
  }

  private collectSlots(lineIndex: number): GlyphSlot[] {
    if (lineIndex < 0 || lineIndex >= this.lines.length) { return []; }
    const line: LyricLine = this.lines[lineIndex];
    const result: GlyphSlot[] = [];
    for (let i = 0; i < line.glyphs.length; i++) {
      result.push({ glyph: line.glyphs[i], index: i });
    }
    return result;
  }

  // Compute the star's X offset from the row center, using actual measured glyph
  // widths so non-uniform text (Chinese, English, punctuation) is handled correctly.
  private computeStarOffsetX(glyphIdx: number): number {
    const slots: GlyphSlot[] = this.currentSlots;
    if (slots.length === 0) { return 0; }
    let total: number = 0;
    let before: number = 0;
    for (let i = 0; i < slots.length; i++) {
      const w: number = this.glyphWidths.get(i) ?? FALLBACK_GLYPH_WIDTH_VP;
      total += w;
      if (i < glyphIdx) { before += w; }
      else if (i === glyphIdx) { before += w / 2; }
    }
    // Row is centered (justifyContent: Center), so star offset from center =
    // glyphCenter - rowCenter = (before) - (total / 2).
    return before - total / 2;
  }

  // Parabolic hop: X interpolates with EaseInOut, Y traces a parabola
  //   y = restY - 4 * jumpHeight * t * (1 - t)
  // The hop duration is derived from the inter-glyph timestamp interval.
  private hopTo(targetX: number, glyphIdx: number): void {
    if (this.hopTimer !== -1) { clearTimeout(this.hopTimer); this.hopTimer = -1; }
    const fromX: number = this.star.x;
    const fromY: number = STAR_REST_Y;
    const jumpHeight: number = STAR_JUMP_HEIGHT_VP;

    // Duration from adjacent glyph timestamps (clamped).
    const line: LyricLine | undefined = this.lines[this.activeLine];
    let hopMs: number = 300;
    if (line && glyphIdx > 0 && glyphIdx < line.glyphs.length) {
      const interval: number = line.glyphs[glyphIdx].start - line.glyphs[glyphIdx - 1].start;
      if (Number.isFinite(interval) && interval > 0) {
        hopMs = Math.max(HOP_MIN_MS, Math.min(HOP_MAX_MS, interval));
      }
    }

    const start: number = Date.now();
    const step = (): void => {
      const elapsed: number = Date.now() - start;
      const t: number = Math.min(1, elapsed / hopMs);
      // X: EaseInOut interpolation.
      const eased: number = t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
      const x: number = fromX + (targetX - fromX) * eased;
      // Y: parabola — 0 at t=0 and t=1, peak (-jumpHeight) at t=0.5.
      const y: number = fromY - 4 * jumpHeight * t * (1 - t);
      this.star = { x, y };
      if (t < 1) {
        this.hopTimer = setTimeout(step, HOP_STEP_MS);
      } else {
        this.hopTimer = -1;
        this.triggerBounce(glyphIdx);
      }
    };
    step();
  }

  // Press the glyph DOWN on star impact, then rebound UP to rest:
  //   phase 0 (rest) → phase 1 (pressed: scale up + translateY +PRESS_VP)
  //   → phase 0 (rebound: scale back to 1.0 + translateY back to 0)
  // EaseIn accelerates the downward press; EaseOut decelerates the rebound.
  private triggerBounce(glyphIdx: number): void {
    if (this.bounceTimer !== -1) { clearTimeout(this.bounceTimer); this.bounceTimer = -1; }
    const ui = this.getUIContext();
    this.bouncingGlyph = glyphIdx;
    this.bouncePhase = 0;
    // Defer the press-phase one frame so the reset (phase=0) is committed first.
    this.bounceTimer = setTimeout(() => {
      ui.animateTo({ duration: PRESS_DOWN_MS, curve: Curve.EaseIn }, () => {
        this.bouncePhase = 1;
      });
      this.bounceTimer = setTimeout(() => {
        ui.animateTo({ duration: REBOUND_MS, curve: Curve.EaseOut }, () => {
          this.bouncePhase = 0;
        });
        this.bounceTimer = -1;
      }, PRESS_DOWN_MS + 10);
    }, 10);
  }

  private adjacent(offset: number): LyricLine | undefined {
    const index: number = this.activeLine + offset;
    if (index < 0 || index >= this.lines.length) { return undefined; }
    return this.lines[index];
  }

  private contextText(line: LyricLine | undefined): string {
    if (!line) { return ' '; }
    return line.text.length > 0 ? line.text : ' ';
  }

  private previewText(): string {
    const upcoming: LyricLine | undefined = this.adjacent(0) ?? this.adjacent(1);
    return upcoming?.text ?? '';
  }

  // ── Per-glyph transform helpers — read reactive state so animateTo drives them. ──

  private glyphScale(idx: number): ScaleOptions {
    if (idx === this.bouncingGlyph && this.bouncePhase === 1) {
      return { x: PRESS_SCALE, y: PRESS_SCALE };
    }
    return { x: 1.0, y: 1.0 };
  }

  // Pressed glyphs translate DOWN by +PRESS_VP (positive Y), not up — this is
  // the "受击下压" effect: star impact pushes the char down before rebounding.
  private glyphTranslateY(idx: number): TranslateOptions {
    if (idx === this.bouncingGlyph && this.bouncePhase === 1) {
      return { y: PRESS_VP };
    }
    return { y: 0 };
  }

  build() {
    Column({ space: 14 }) {
      if (this.loading) {
        Text('歌词加载中…')
          .fontSize(13).fontColor(this.inactiveColor)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.lines.length === 0) {
        Text(this.label.length > 0 ? this.label : '纯音乐 · 暂无歌词')
          .fontSize(13).fontColor(this.inactiveColor)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.activeLine < 0) {
        Text(this.previewText())
          .fontSize(this.inactiveSize).fontColor(this.inactiveColor)
          .opacity(0.85).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        if (this.showContext) {
          Text(this.contextText(this.adjacent(-1)))
            .fontSize(this.inactiveSize).fontColor(this.inactiveColor)
            .opacity(0.6)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        this.activeRow()
        if (this.showContext) {
          Text(this.contextText(this.adjacent(1)))
            .fontSize(this.inactiveSize).fontColor(this.inactiveColor)
            .opacity(0.6)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      if (this.lines.length > 0 && this.label.length > 0) {
        Text(this.label).fontSize(10).fontColor(this.inactiveColor).opacity(0.7).margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  private activeRow() {
    Stack({ alignContent: Alignment.Top }) {
      // ── Star layer: full-width row, star centered + offset. ──
      Row() {
        Image($r('app.media.lyric_star'))
          .width(STAR_SIZE_VP)
          .height(STAR_SIZE_VP)
          .offset({ x: this.star.x, y: this.star.y })
          .zIndex(2)
      }
      .width('100%')
      .height(STAR_SIZE_VP)
      .justifyContent(FlexAlign.Center)

      // ── Glyph layer: each char is its own Text so widths are measured individually. ──
      Row() {
        ForEach(this.currentSlots, (slot: GlyphSlot) => {
          Text(slot.glyph.text)
            .fontSize(this.activeSize)
            .fontColor(slot.index <= this.activeGlyph ? this.activeColor : this.inactiveColor)
            .fontWeight(FontWeight.Bold)
            .opacity(slot.index <= this.activeGlyph ? 1 : 0.55)
            .scale(this.glyphScale(slot.index))
            .translate(this.glyphTranslateY(slot.index))
            .onAreaChange((oldValue: Area, newValue: Area) => {
              // Area.width is Length (number|string); coerce to vp number for math.
              const w: number = typeof newValue.width === 'number' ? newValue.width : Number(newValue.width);
              const prev: number | undefined = this.glyphWidths.get(slot.index);
              if (prev !== w) {
                this.glyphWidths.set(slot.index, w);
                // Refine star X as real widths arrive (non-uniform text support).
                if (this.wasReady && this.activeGlyph >= 0) {
                  this.star = { x: this.computeStarOffsetX(this.activeGlyph), y: this.star.y };
                }
              }
            })
        }, (slot: GlyphSlot) => `${this.activeLine}:${slot.index}`)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Bottom)
      .offset({ y: STAR_SIZE_VP + STAR_GAP_VP })
    }
    .width('100%')
    .height(STAR_SIZE_VP + STAR_GAP_VP + ROW_HEIGHT)
    .clip(false)
  }
}
