/*-------------------------------------------------------------------------
 *
 * copy.h
 *	  Definitions for using the POSTGRES copy command.
 *
 *
 * Portions Copyright (c) 1996-2017, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/commands/copy.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef COPY_H
#define COPY_H

#include "nodes/execnodes.h"
#include "nodes/parsenodes.h"
#include "parser/parse_node.h"
#include "tcop/dest.h"

/* CopyStateData is private in commands/copy.c */
typedef struct CopyStateData *CopyState;
typedef struct CopyFromStateData *CopyFromState;
typedef int (*copy_data_source_cb) (void *outbuf, int minread, int maxread);

extern void DoCopy(ParseState *state, const CopyStmt *stmt,
	   int stmt_location, int stmt_len,
	   uint64 *processed);

extern void ProcessCopyOptions(ParseState *pstate, CopyState cstate, bool is_from, List *options);
extern CopyState BeginCopyFrom(ParseState *pstate, Relation rel, const char *filename,
			  bool is_program, copy_data_source_cb data_source_cb, List *attnamelist, List *options);
extern void EndCopyFrom(CopyState cstate);
extern int NextCopyFrom(CopyState cstate, ExprContext *econtext,
			 Datum *values, bool *nulls, Oid *tupleOid);
extern bool NextCopyFromRawFields(CopyState cstate,
					  char ***fields, int *nfields);
extern void CopyFromErrorCallback(void *arg);

extern void CopyFromBgwMainLoop(Datum main_arg);
extern uint64 CopyFrom(CopyState cstate);
extern uint64 ParallelCopyFrom(CopyState cstate, ParseState *pstate,
			  Relation rel,
			  const char *filename,
			  bool is_program,
			  List *attnamelist,
			  List *options);

extern DestReceiver *CreateCopyDestReceiver(void);

#endif							/* COPY_H */
