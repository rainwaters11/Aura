import {spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {SceneFrame} from '../components/SceneFrame';
import {COLORS} from '../theme';

const steps = [
  ['01', 'Park', 'Hold exact-input intent without moving the curve'],
  ['02', 'Match', 'Clear compatible flow at one uniform price'],
  ['03', 'Residual', 'Send only the unmatched difference to Uniswap'],
  ['04', 'Claim', 'Credit recipient-controlled output claims'],
];

export const Architecture = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  return (
    <SceneFrame eyebrow="How Aura works" title="The pool becomes the residual venue." subtitle="The hook verifies every transition, while users retain an independent timeout-refund path.">
      <div style={{position: 'absolute', left: 110, right: 110, top: 500, display: 'flex', gap: 24}}>
        {steps.map(([number, title, body], index) => {
          const reveal = spring({frame: frame - index * 16, fps, config: {damping: 20}});
          return (
            <div key={number} style={{flex: 1, minHeight: 305, padding: 34, borderRadius: 28, border: `1px solid ${index === 2 ? COLORS.gold : COLORS.emerald}55`, background: '#0b201ddd', opacity: reveal, transform: `translateY(${(1 - reveal) * 45}px)`}}>
              <div style={{color: index === 2 ? COLORS.gold : COLORS.emerald, fontSize: 28, fontWeight: 800}}>{number}</div>
              <div style={{fontSize: 41, fontWeight: 770, marginTop: 36}}>{title}</div>
              <div style={{color: COLORS.muted, fontSize: 24, lineHeight: 1.42, marginTop: 22}}>{body}</div>
            </div>
          );
        })}
      </div>
    </SceneFrame>
  );
};
