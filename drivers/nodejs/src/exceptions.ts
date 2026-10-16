/**
 * Exception hierarchy for the MaluDB Node.js driver.
 *
 * SQLSTATE-class translation mirrors the Python driver: callers can
 * `catch (e) { if (e instanceof MaluDBNotFound) ... }` instead of
 * digging through `node-postgres` `DatabaseError.code`.
 */

import type { DatabaseError } from "pg";

export class MaluDBError extends Error {
  override readonly name: string = "MaluDBError";
  readonly sqlstate?: string;
  readonly detail?: string;

  constructor(message: string, sqlstate?: string, detail?: string) {
    super(message);
    this.sqlstate = sqlstate;
    this.detail = detail;
  }
}

export class MaluDBNotFound extends MaluDBError {
  override readonly name = "MaluDBNotFound";
}

export class MaluDBInvalidParameter extends MaluDBError {
  override readonly name = "MaluDBInvalidParameter";
}

export class MaluDBObjectNotInPrerequisiteState extends MaluDBError {
  override readonly name = "MaluDBObjectNotInPrerequisiteState";
}

export class MaluDBCheckViolation extends MaluDBError {
  override readonly name = "MaluDBCheckViolation";
}

export class MaluDBPermissionDenied extends MaluDBError {
  override readonly name = "MaluDBPermissionDenied";
}

const SQLSTATE_MAP: Record<string, new (m: string, s?: string, d?: string) => MaluDBError> = {
  P0002: MaluDBNotFound,
  "02000": MaluDBNotFound,
  "22023": MaluDBInvalidParameter,
  "22P02": MaluDBInvalidParameter,
  "55000": MaluDBObjectNotInPrerequisiteState,
  "23514": MaluDBCheckViolation,
  "42501": MaluDBPermissionDenied,
};

export function translate(exc: unknown): MaluDBError {
  if (exc && typeof exc === "object" && "code" in exc && typeof (exc as DatabaseError).code === "string") {
    const dbErr = exc as DatabaseError;
    const Ctor = SQLSTATE_MAP[dbErr.code ?? ""] ?? MaluDBError;
    return new Ctor(dbErr.message, dbErr.code, dbErr.detail);
  }
  if (exc instanceof Error) {
    return new MaluDBError(exc.message);
  }
  return new MaluDBError(String(exc));
}
