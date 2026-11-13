// All prices in the app are whole Korean won (KRW). There are no decimals.

const krw = new Intl.NumberFormat('ko-KR');

/** 139000 -> "₩139,000" */
export function formatKRW(amount: number): string {
  return `₩${krw.format(Math.round(amount))}`;
}
