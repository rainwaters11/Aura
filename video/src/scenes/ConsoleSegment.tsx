import {AbsoluteFill, OffthreadVideo, staticFile} from 'remotion';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

export const ConsoleSegment = ({clip}: {clip?: string}) => {
  if (clip) {
    return (
      <AbsoluteFill style={{background: COLORS.ink}}>
        <OffthreadVideo src={staticFile(clip)} style={{width: '100%', height: '100%', objectFit: 'contain'}} />
        <div style={{position: 'absolute', right: 42, top: 36, padding: '13px 20px', borderRadius: 999, background: '#071312dd', color: COLORS.emerald, fontFamily: 'Inter, sans-serif', fontSize: 21, fontWeight: 760}}>
          DETERMINISTIC LOCAL DEMONSTRATION
        </div>
      </AbsoluteFill>
    );
  }

  return (
    <SceneFrame eyebrow="Real product demonstration" title="Insert the genuine Aura console capture" subtitle="Record: Load demo orders → Close batch → Submit solution → Claim 4 WETH.">
      <div style={{position: 'absolute', left: 180, right: 180, top: 500, height: 360, borderRadius: 32, border: `2px dashed ${COLORS.emerald}88`, background: '#0b201daa', display: 'grid', placeItems: 'center', textAlign: 'center'}}>
        <div>
          <div style={{fontSize: 42, fontWeight: 780}}>public/clips/console-demo.mp4</div>
          <div style={{fontSize: 25, color: COLORS.muted, marginTop: 18}}>Use real browser footage. Never replace this section with generated imagery.</div>
        </div>
      </div>
    </SceneFrame>
  );
};
