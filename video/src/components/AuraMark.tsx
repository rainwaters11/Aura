import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {COLORS} from '../theme';

type AuraMarkProps = {size?: number; showWordmark?: boolean};

export const AuraMark = ({size = 360, showWordmark = true}: AuraMarkProps) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const entrance = spring({frame, fps, config: {damping: 18, stiffness: 85}});
  const rotate = interpolate(frame, [0, 240], [-18, 18]);
  const pulse = 0.92 + Math.sin(frame / 18) * 0.045;

  return (
    <div style={{display: 'flex', alignItems: 'center', gap: 44, transform: `scale(${entrance})`, opacity: entrance}}>
      <div style={{position: 'relative', width: size, height: size, transform: `rotate(${rotate}deg) scale(${pulse})`}}>
        <div
          style={{
            position: 'absolute',
            inset: size * 0.07,
            borderRadius: '50%',
            border: `${size * 0.045}px solid ${COLORS.emerald}`,
            borderRightColor: 'transparent',
            boxShadow: `0 0 55px ${COLORS.emerald}66`,
          }}
        />
        <div
          style={{
            position: 'absolute',
            inset: size * 0.2,
            borderRadius: '50%',
            border: `${size * 0.04}px solid ${COLORS.violet}`,
            borderLeftColor: 'transparent',
            boxShadow: `0 0 45px ${COLORS.violet}55`,
          }}
        />
        <div
          style={{
            position: 'absolute',
            left: '50%',
            top: '50%',
            width: size * 0.18,
            height: size * 0.18,
            transform: 'translate(-50%, -50%) rotate(45deg)',
            borderRadius: size * 0.025,
            background: COLORS.gold,
            boxShadow: `0 0 70px ${COLORS.gold}`,
          }}
        />
      </div>
      {showWordmark && (
        <div>
          <div style={{fontSize: size * 0.34, fontWeight: 800, letterSpacing: size * 0.035, lineHeight: 0.9}}>AURA</div>
          <div style={{color: COLORS.emerald, fontSize: size * 0.075, letterSpacing: size * 0.025, marginTop: size * 0.065}}>
            COORDINATED SETTLEMENT
          </div>
        </div>
      )}
    </div>
  );
};
