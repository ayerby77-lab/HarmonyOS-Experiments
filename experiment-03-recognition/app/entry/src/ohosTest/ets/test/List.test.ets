import InferenceEngineTest from './InferenceEngine.test';
import ImageAssetStoreTest from './ImageAssetStore.test';

export default function testsuite(): void {
  InferenceEngineTest();
  ImageAssetStoreTest();
}
