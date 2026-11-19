declare module "*.css";
declare module "*?worker" { const W: { new (): Worker }; export default W; }
declare module "monaco-editor/basic-languages/monaco.contribution";
declare module "monaco-editor/editor/contrib/find/browser/findController";
