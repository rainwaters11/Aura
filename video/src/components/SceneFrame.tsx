import type {ReactNode} from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {COLORS} from '../theme';

type SceneFrameProps = {
  children: ReactNode;
  eyebrow?: string;
  title?: string;
  subtitle?: string;
};

export const SceneFrame = ({children, eyebrow, title, subtitle}: SceneFrameProps) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});
  const rise = interpolate(frame, [0, 22], [30, 0], {extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(circle at 78% 12%, ${COLORS.inkSoft} 0%, ${COLORS.ink} 48%, #030908 100%)`,
        color: COLORS.cream,
        fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif',
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: 0.24,
          backgroundImage:
            'linear-gradient(rgba(101,231,255,.08) 1px, transparent 1px), linear-gradient(90deg, rgba(101,231,255,.08) 1px, transparent 1px)',
          backgroundSize: '72px 72px',
          transform: `translateY(${(frame % 72) - 72}px)`,
        }}
      />
      {(eyebrow || title || subtitle) && (
        <div
          style={{
            position: 'absolute',
            left: 112,
            top: 88,
            width: 1200,
            opacity,
            transform: `translateY(${rise}px)`,
            zIndex: 10,
          }}
        >
          {eyebrow && (
            <div style={{color: COLORS.emerald, fontSize: 26, fontWeight: 760, letterSpacing: 4, textTransform: 'uppercase'}}>
              {eyebrow}
            </div>
          )}
          {title && <div style={{fontSize: 76, fontWeight: 780, lineHeight: 1.04, marginTop: 18}}>{title}</div>}
          {subtitle && <div style={{color: COLORS.muted, fontSize: 31, lineHeight: 1.42, marginTop: 20, maxWidth: 1050}}>{subtitle}</div>}
        </div>
      )}
      {children}
      <div style={{position: 'absolute', left: 112, bottom: 60, color: COLORS.muted, fontSize: 21, letterSpacing: 2}}>
        AURA · MATCH FIRST · SETTLE ONLY WHAT REMAINS
      </div>
    </AbsoluteFill>
  );
};
