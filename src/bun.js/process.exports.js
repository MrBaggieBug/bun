export const chdir = process.chdir.bind(process);
export const cwd = process.cwd.bind(process);
export const nextTick = process.nextTick.bind(process);
export const browser = false;
export var exitCode = process.exitCode;
export const exit = process.exit.bind(process);
export const pid = process.pid;
export const ppid = process.ppid;
export const release = process.release;
export const version = process.version;
export const versions = process.versions;
export const arch = process.arch;
export const platform = process.platform;