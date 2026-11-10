import type { CloudflareRegisterResponse, CloudflareWarpResponse } from '@/types';
import { Buffer } from 'buffer';

const BASE_URL = 'https://api.cloudflareclient.com/v0i1909051800';
const MASQUE_BASE_URL = 'https://api.cloudflareclient.com/v0a4471';

const DEFAULT_HEADERS = {
  'User-Agent': 'okhttp/3.12.1',
  'Content-Type': 'application/json',
};

const MASQUE_HEADERS = {
  'User-Agent': 'WARP for Android',
  'CF-Client-Version': 'a-6.35-4471',
  'Content-Type': 'application/json; charset=UTF-8',
};
