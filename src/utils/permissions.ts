import { chmodSync, mkdirSync, existsSync, statSync } from 'fs';
import { execSync, spawnSync } from 'child_process';
import { dirname } from 'path';
import { logger } from './logger.js';

/**
 * Permission mode constants
 * Note: Using 755 instead of 777 for security - owner has full access,
 * group and others can read/execute but not write
 */
export const PERMISSIONS = {
  FULL_ACCESS: 0o755,    // rwxr-xr-x - Secure default (was 777)
  OWNER_FULL: 0o700,     // rwx------ - Owner only
  GROUP_WRITE: 0o775,    // rwxrwxr-x - Owner/group write
  READ_ONLY: 0o444,      // r--r--r-- - Read only for all
  EXECUTABLE: 0o755,     // rwxr-xr-x - Executable
  LEGACY_FULL: 0o777,    // rwxrwxrwx - Legacy full access (avoid using)
} as const;

/**
 * Check if the current process is running as root
 */
export function isRunningAsRoot(): boolean {
  return process.getuid?.() === 0;
}

/**
 * Check if we have sudo access available
 */
export function hasSudoAccess(): boolean {
  try {
    const result = spawnSync('sudo', ['-n', 'true'], {
      stdio: 'pipe',
      timeout: 5000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

/**
 * Request root access - logs warning if not available
 */
export function requestRootAccess(): { isRoot: boolean; hasSudo: boolean; message: string } {
  const isRoot = isRunningAsRoot();
  const hasSudo = hasSudoAccess();

  if (isRoot) {
    logger.info('Running with root privileges');
    return {
      isRoot: true,
      hasSudo: true,
      message: 'Running as root - full permissions available',
    };
  }

  if (hasSudo) {
    logger.info('Sudo access available - can elevate privileges when needed');
    return {
      isRoot: false,
      hasSudo: true,
      message: 'Sudo access available - can request elevated privileges',
    };
  }

  logger.warn('Not running as root and sudo not available - some operations may fail');
  return {
    isRoot: false,
    hasSudo: false,
    message: 'Limited permissions - run with sudo for full access',
  };
}

/**
 * Set file permissions (defaults to 777 for full access)
 */
export function setFilePermissions(
  filePath: string,
  mode: number = PERMISSIONS.FULL_ACCESS
): { success: boolean; error?: string } {
  try {
    if (!existsSync(filePath)) {
      return { success: false, error: `File not found: ${filePath}` };
    }

    // Try direct chmod first
    try {
      chmodSync(filePath, mode);
      logger.debug({ filePath, mode: mode.toString(8) }, 'Set file permissions');
      return { success: true };
    } catch (directError) {
      // If direct chmod fails, try with sudo
      if (hasSudoAccess()) {
        try {
          execSync(`sudo chmod ${mode.toString(8)} "${filePath}"`, {
            stdio: 'pipe',
            timeout: 10000,
          });
          logger.debug({ filePath, mode: mode.toString(8) }, 'Set file permissions via sudo');
          return { success: true };
        } catch (sudoError) {
          return {
            success: false,
            error: `Failed to set permissions even with sudo: ${sudoError instanceof Error ? sudoError.message : String(sudoError)}`,
          };
        }
      }
      return {
        success: false,
        error: `Permission denied and no sudo access: ${directError instanceof Error ? directError.message : String(directError)}`,
      };
    }
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Create directory with full permissions (777)
 */
export function createDirectoryWithFullAccess(
  dirPath: string
): { success: boolean; error?: string } {
  try {
    // Create parent directories if needed
    const parentDir = dirname(dirPath);
    if (!existsSync(parentDir)) {
      mkdirSync(parentDir, { recursive: true, mode: PERMISSIONS.FULL_ACCESS });
    }

    if (!existsSync(dirPath)) {
      mkdirSync(dirPath, { recursive: true, mode: PERMISSIONS.FULL_ACCESS });
    }

    // Ensure permissions are set correctly
    return setFilePermissions(dirPath, PERMISSIONS.FULL_ACCESS);
  } catch (error) {
    // Try with sudo if direct creation fails
    if (hasSudoAccess()) {
      try {
        execSync(`sudo mkdir -p "${dirPath}" && sudo chmod 755 "${dirPath}"`, {
          stdio: 'pipe',
          timeout: 10000,
        });
        return { success: true };
      } catch (sudoError) {
        return {
          success: false,
          error: `Failed to create directory even with sudo: ${sudoError instanceof Error ? sudoError.message : String(sudoError)}`,
        };
      }
    }
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Set permissions recursively on a directory
 */
export function setPermissionsRecursive(
  dirPath: string,
  mode: number = PERMISSIONS.FULL_ACCESS
): { success: boolean; error?: string; filesModified: number } {
  let filesModified = 0;

  try {
    if (!existsSync(dirPath)) {
      return { success: false, error: `Directory not found: ${dirPath}`, filesModified: 0 };
    }

    // Use chmod -R for efficiency
    try {
      execSync(`chmod -R ${mode.toString(8)} "${dirPath}"`, {
        stdio: 'pipe',
        timeout: 30000,
      });
      filesModified = -1; // Unknown exact count with -R
      return { success: true, filesModified };
    } catch (directError) {
      // Try with sudo
      if (hasSudoAccess()) {
        try {
          execSync(`sudo chmod -R ${mode.toString(8)} "${dirPath}"`, {
            stdio: 'pipe',
            timeout: 30000,
          });
          return { success: true, filesModified: -1 };
        } catch (sudoError) {
          return {
            success: false,
            error: `Failed to set recursive permissions: ${sudoError instanceof Error ? sudoError.message : String(sudoError)}`,
            filesModified,
          };
        }
      }
      return {
        success: false,
        error: `Permission denied: ${directError instanceof Error ? directError.message : String(directError)}`,
        filesModified,
      };
    }
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
      filesModified,
    };
  }
}

/**
 * Get current file permissions
 */
export function getFilePermissions(filePath: string): { mode: string; owner: number; group: number } | null {
  try {
    const stats = statSync(filePath);
    return {
      mode: (stats.mode & 0o777).toString(8).padStart(3, '0'),
      owner: stats.uid,
      group: stats.gid,
    };
  } catch {
    return null;
  }
}

/**
 * Execute command with root privileges if needed
 */
export function executeAsRoot(
  command: string,
  options: { timeout?: number; cwd?: string } = {}
): { success: boolean; output?: string; error?: string } {
  const timeout = options.timeout || 30000;
  const cwd = options.cwd;

  try {
    // If already root, execute directly
    if (isRunningAsRoot()) {
      const output = execSync(command, {
        stdio: 'pipe',
        timeout,
        cwd,
        encoding: 'utf-8',
      });
      return { success: true, output };
    }

    // If sudo available, use it
    if (hasSudoAccess()) {
      const output = execSync(`sudo ${command}`, {
        stdio: 'pipe',
        timeout,
        cwd,
        encoding: 'utf-8',
      });
      return { success: true, output };
    }

    // Try without elevation
    try {
      const output = execSync(command, {
        stdio: 'pipe',
        timeout,
        cwd,
        encoding: 'utf-8',
      });
      return { success: true, output };
    } catch (error) {
      return {
        success: false,
        error: `Command failed and no root access available: ${error instanceof Error ? error.message : String(error)}`,
      };
    }
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Ensure MCP tool directories exist with proper permissions
 */
export function ensureMcpToolDirectories(basePath: string): { success: boolean; errors: string[] } {
  const errors: string[] = [];
  const directories = [
    `${basePath}/data`,
    `${basePath}/logs`,
    `${basePath}/cache`,
    `${basePath}/temp`,
    `${basePath}/uploads`,
    `${basePath}/downloads`,
    `${basePath}/screenshots`,
    `${basePath}/workspace`,
  ];

  for (const dir of directories) {
    const result = createDirectoryWithFullAccess(dir);
    if (!result.success) {
      errors.push(`${dir}: ${result.error}`);
    }
  }

  if (errors.length > 0) {
    logger.warn({ errors }, 'Some MCP tool directories could not be created with full permissions');
    return { success: false, errors };
  }

  logger.info({ directories }, 'MCP tool directories created with secure permissions (755)');
  return { success: true, errors: [] };
}

/**
 * Initialize permissions system and verify access level
 */
export function initializePermissions(): {
  isRoot: boolean;
  hasSudo: boolean;
  recommendations: string[];
} {
  const accessInfo = requestRootAccess();
  const recommendations: string[] = [];

  if (!accessInfo.isRoot && !accessInfo.hasSudo) {
    recommendations.push('Run the gateway with sudo for full permissions: sudo npm start');
    recommendations.push('Or configure sudoers for passwordless access to specific commands');
    recommendations.push('Some MCP tools may have limited functionality without root access');
  } else if (!accessInfo.isRoot && accessInfo.hasSudo) {
    recommendations.push('Running with sudo access - elevated operations will be performed via sudo');
  }

  logger.info({
    isRoot: accessInfo.isRoot,
    hasSudo: accessInfo.hasSudo,
    platform: process.platform,
    uid: process.getuid?.(),
  }, 'Permissions system initialized');

  return {
    isRoot: accessInfo.isRoot,
    hasSudo: accessInfo.hasSudo,
    recommendations,
  };
}

/**
 * Change ownership of file/directory
 */
export function changeOwnership(
  path: string,
  owner: string,
  group?: string
): { success: boolean; error?: string } {
  try {
    const target = group ? `${owner}:${group}` : owner;
    const command = `chown ${target} "${path}"`;

    const result = executeAsRoot(command);
    if (result.success) {
      logger.debug({ path, owner, group }, 'Changed ownership');
    }
    return result;
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Change ownership recursively
 */
export function changeOwnershipRecursive(
  path: string,
  owner: string,
  group?: string
): { success: boolean; error?: string } {
  try {
    const target = group ? `${owner}:${group}` : owner;
    const command = `chown -R ${target} "${path}"`;

    const result = executeAsRoot(command);
    if (result.success) {
      logger.debug({ path, owner, group }, 'Changed ownership recursively');
    }
    return result;
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
