// VoiceService wraps HarmonyOS Speech Kit + AudioCapturer behind a Promise-based
// API: `await voiceService.listen()` returns the recognized Mandarin text.
// - Engine: @kit.CoreSpeechKit speechRecognizer (offline Mandarin ASR)
// - Audio:  @kit.AudioKit audio.AudioCapturer (16k mono 16-bit PCM mic stream)
// - Permission: @kit.AbilityKit abilityAccessCtrl.AtManager for ohos.permission.MICROPHONE

import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'MusicApp.VoiceService';
const DOMAIN: number = 0x0000;
const SESSION_ID: string = 'musicapp-voice-session';
const SILENCE_TIMEOUT_MS: number = 6000;

export class VoiceService {
  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private listening: boolean = false;
  private context: common.UIAbilityContext;
  private permissionChecked: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // Ensure the user has granted MICROPHONE. Result is cached so repeated
  // listen() calls skip the permission dialog after the first grant.
  async ensurePermission(): Promise<boolean> {
    if (this.permissionChecked) {
      return true;
    }
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const tokenId: number = this.context.applicationInfo.accessTokenId;
    try {
      const status: abilityAccessCtrl.GrantStatus =
        await manager.checkAccessToken(tokenId, 'ohos.permission.MICROPHONE');
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.permissionChecked = true;
        return true;
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'checkAccessToken failed: %{public}s', (error as BusinessError).message);
    }
    try {
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(this.context, ['ohos.permission.MICROPHONE']);
      const granted: boolean = result.authResults.length > 0 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      this.permissionChecked = granted;
      return granted;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'permission request failed: %{public}s', (error as BusinessError).message);
      return false;
    }
  }

  private async ensureEngine(): Promise<void> {
    if (this.engine) {
      return;
    }
    this.engine = await speechRecognizer.createEngine({
      language: 'zh-CN',
      online: 1,
      extraParams: {
        'locate': 'CN',
        'recognizerMode': 'short'
      }
    });
  }

  // Start a single recognition session and resolve with the recognized text.
  // Rejects if permission is denied, the engine fails, or the silence timer
  // expires without any speech.
  async listen(): Promise<string> {
    if (this.listening) {
      return '';
    }
    const granted: boolean = await this.ensurePermission();
    if (!granted) {
      return Promise.reject(new Error('未授予麦克风权限，无法识别语音'));
    }
    await this.ensureEngine();
    const engine = this.engine;
    if (!engine) {
      return Promise.reject(new Error('语音识别引擎未就绪'));
    }
    this.listening = true;
    // Set up the capturer BEFORE registering the listener so that the first
    // readData event after startListening is never dropped.
    this.capturer = await audio.createAudioCapturer({
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: {
        source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION,
        capturerFlags: 0
      }
    });
    const capturer: audio.AudioCapturer = this.capturer;
    return new Promise<string>((resolve, reject) => {
      let settled: boolean = false;
      let finalText: string = '';
      const silenceTimer: number = setTimeout(() => {
        hilog.info(DOMAIN, TAG, 'silence timeout, finishing session');
        try { engine.finish(SESSION_ID); } catch (error) {}
      }, SILENCE_TIMEOUT_MS);
      const finish = (text: string) => {
        if (settled) { return; }
        settled = true;
        clearTimeout(silenceTimer);
        this.listening = false;
        this.teardown(capturer);
        resolve(text);
      };
      const fail = (error: BusinessError | Error) => {
        if (settled) { return; }
        settled = true;
        clearTimeout(silenceTimer);
        this.listening = false;
        this.teardown(capturer);
        reject(error);
      };
      // Route mic buffers into the ASR engine. writeAudio requires a Uint8Array view
      // backed by a non-shared ArrayBuffer; the capturer emits a fresh ArrayBuffer
      // per readData so we can wrap it directly.
      capturer.on('readData', (buffer: ArrayBuffer) => {
        try {
          engine.writeAudio(SESSION_ID, new Uint8Array(buffer));
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'writeAudio failed: %{public}s', (error as BusinessError).message);
        }
      });
      capturer.on('stateChange', (state: audio.AudioState) => {
        hilog.info(DOMAIN, TAG, 'capturer state: %{public}d', state);
      });
      engine.setListener({
        onStart: (sessionId: string, message: string) => {
          hilog.info(DOMAIN, TAG, 'asr start %{public}s %{public}s', sessionId, message);
        },
        onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
          // eventCode 3 = vadEnd (speech stopped). When that fires, finalize so
          // we don't sit through the full silence timeout waiting for onComplete.
          hilog.info(DOMAIN, TAG, 'asr event %{public}d %{public}s', eventCode, eventMessage);
          if (eventCode === 3) {
            try { engine.finish(SESSION_ID); } catch (error) {}
          }
        },
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          // The engine emits intermediate (isFinal=false) and final (isFinal=true)
          // results. We resolve on the first final result with non-empty text.
          if (result.isFinal && result.result.length > 0) {
            finalText = result.result;
            finish(finalText);
          } else if (result.result.length > 0) {
            finalText = result.result;
          }
        },
        onComplete: (sessionId: string, message: string) => {
          hilog.info(DOMAIN, TAG, 'asr complete %{public}s %{public}s', sessionId, message);
          // Resolve with whatever final text we have, even if empty (silence).
          finish(finalText);
        },
        onError: (sessionId: string, errorCode: number, errorMessage: string) => {
          hilog.error(DOMAIN, TAG, 'asr error %{public}d: %{public}s', errorCode, errorMessage);
          fail({ code: errorCode, message: errorMessage } as BusinessError);
        }
      });
      try {
        engine.startListening({
          sessionId: SESSION_ID,
          audioInfo: {
            audioType: 'pcm',
            sampleRate: 16000,
            soundChannel: 1,
            sampleBit: 16
          }
        });
        capturer.start().catch((error: BusinessError): void => { fail(error); });
      } catch (error) {
        fail(error as BusinessError);
      }
    });
  }

  // Stop the capturer and end the engine's current session. Safe to call from
  // listen() promise resolution path.
  private teardown(capturer: audio.AudioCapturer): void {
    capturer.off('readData');
    capturer.off('stateChange');
    capturer.stop().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'capturer.stop failed: %{public}s', error.message);
    });
    capturer.release().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'capturer.release failed: %{public}s', error.message);
    });
  }

  // Cancel an in-flight session (e.g. user dismissed the UI).
  cancel(): void {
    if (!this.listening) { return; }
    if (this.engine) {
      try { this.engine.cancel(SESSION_ID); } catch (error) {
        hilog.warn(DOMAIN, TAG, 'cancel failed: %{public}s', (error as BusinessError).message);
      }
    }
    if (this.capturer) {
      this.teardown(this.capturer);
    }
    this.listening = false;
  }

  dispose(): void {
    this.cancel();
    if (this.engine) {
      try { this.engine.shutdown(); } catch (error) {
        hilog.warn(DOMAIN, TAG, 'shutdown failed: %{public}s', (error as BusinessError).message);
      }
      this.engine = undefined;
    }
    this.permissionChecked = false;
  }
}
