import type { ReactNode } from 'react';
import logoWhite from '../assets/brand/reqaz-logo-white.svg';
import mark from '../assets/brand/reqaz-mark.svg';

/** Sidebar lockup: the bar mark with the spaced REQAZ wordmark. */
export function BrandLockup({ subtitle }: { subtitle: string }) {
  return (
    <div className="flex items-center gap-3">
      <img src={mark} alt="" className="h-9 w-auto" />
      <div className="leading-tight">
        <div className="text-sm font-medium tracking-[0.45em] text-ink">REQAZ</div>
        <div className="text-[11px] text-slate-500">{subtitle}</div>
      </div>
    </div>
  );
}

/** Full-screen sign-in backdrop in the brand's dark colourway, with the white logo above the card. */
export function AuthScreen({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-brand-900 p-4">
      <img src={logoWhite} alt="REQAZ" className="mb-8 h-28 w-auto" />
      <div className="w-full max-w-md rounded-xl border-t-4 border-gold bg-white p-6 shadow-2xl">{children}</div>
    </div>
  );
}
