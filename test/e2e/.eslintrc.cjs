/* Eslint config for the standalone Playwright e2e (mirrors apps/stream-only). */
module.exports = {
  root: true,
  env: { browser: true, es2021: true, node: true },
  parser: '@typescript-eslint/parser',
  parserOptions: { ecmaVersion: 2021, sourceType: 'module' },
  plugins: ['@typescript-eslint'],
  extends: ['eslint:recommended', 'plugin:@typescript-eslint/recommended'],
  ignorePatterns: ['node_modules/', 'playwright-report/', 'test-results/'],
  rules: {
    'no-console': 'off',
  },
};
