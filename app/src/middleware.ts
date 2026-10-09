import { NextResponse, type NextRequest } from "next/server";

// Inlined at build time. Comma-separated ISO 3166-1 alpha-2 codes; empty = geoblock off.
const BLOCKED = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function middleware(req: NextRequest) {
  if (BLOCKED.length === 0) return NextResponse.next();
  const { pathname } = req.nextUrl;
  // The risk page stays reachable so blocked visitors can read why.
  if (pathname === "/blocked" || pathname === "/risk") return NextResponse.next();
  // Vercel geo header (absent locally / on other hosts -> pass through).
  const country = (req.headers.get("x-vercel-ip-country") ?? "").toUpperCase();
  if (country && BLOCKED.includes(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    url.search = "";
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  // Skip Next internals and static files.
  matcher: ["/((?!_next/|favicon.ico|icon.svg|.*\\.(?:png|jpg|jpeg|svg|ico|webp|txt|xml)$).*)"],
};
