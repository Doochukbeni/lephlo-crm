import { type IconComponentProps } from 'twenty-ui/icon';

// The UAE dirham symbol adopted by the Central Bank of the UAE in 2025 (a D
// crossed by two bars), drawn on Tabler's 24px grid so it sits with the other
// currency icons. Tabler's IconCurrencyDirham draws the older "د.إ" letters,
// which read as "⅃⁾" at 16px.
type IconCurrencyUaeDirhamProps = IconComponentProps;

export const IconCurrencyUaeDirham = ({
  className,
  style,
  size = 24,
  stroke = 2,
  color = 'currentColor',
  'aria-hidden': ariaHidden = true,
}: IconCurrencyUaeDirhamProps) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    className={className}
    style={style}
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth={stroke}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden={ariaHidden}
  >
    <path d="M7 5v14h3a7 7 0 0 0 0 -14z" />
    <path d="M4 10h16" />
    <path d="M4 14h16" />
  </svg>
);
