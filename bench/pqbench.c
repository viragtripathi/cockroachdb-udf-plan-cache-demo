// pqbench: reproduces the application's access pattern with libpq.
// Each statement is prepared once with PQprepare, then run many times with
// PQexecPrepared and different bind values.
//
// usage: pqbench <conninfo> <sql> <iterations> [setup-sql ...]
//   $1 is bound to an account id 'A0000001'..'A0050000' (cycled) and $2 to
//   'BANK01'. Each setup-sql argument runs with PQexec before PQprepare.
//   Set PGAPPNAME to tag the run in CockroachDB's statement statistics.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libpq-fe.h>

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <conninfo> <sql> <iterations> [setup-sql ...]\n", argv[0]);
    return 2;
  }
  const char *conninfo = argv[1], *sql = argv[2];
  int iters = atoi(argv[3]);
  if (iters <= 0) {
    fprintf(stderr, "iterations must be > 0\n");
    return 2;
  }

  PGconn *conn = PQconnectdb(conninfo);
  if (PQstatus(conn) != CONNECTION_OK) {
    fprintf(stderr, "connect failed: %s", PQerrorMessage(conn));
    return 1;
  }
  for (int i = 4; i < argc; i++) {
    PGresult *r = PQexec(conn, argv[i]);
    if (PQresultStatus(r) != PGRES_COMMAND_OK && PQresultStatus(r) != PGRES_TUPLES_OK) {
      fprintf(stderr, "setup '%s' failed: %s", argv[i], PQerrorMessage(conn));
      return 1;
    }
    PQclear(r);
  }

  PGresult *r = PQprepare(conn, "s1", sql, 2, NULL);
  if (PQresultStatus(r) != PGRES_COMMAND_OK) {
    fprintf(stderr, "prepare failed: %s", PQerrorMessage(conn));
    return 1;
  }
  PQclear(r);

  double *lat = malloc(sizeof(double) * iters);
  char account_id[32];
  const char *vals[2] = {account_id, "BANK01"};
  double total = 0;
  for (int i = 0; i < iters; i++) {
    snprintf(account_id, sizeof account_id, "A%07d", (int)(((long)i * 7919) % 50000) + 1);
    double start = now_us();
    r = PQexecPrepared(conn, "s1", 2, vals, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
      fprintf(stderr, "exec %d failed: %s", i, PQerrorMessage(conn));
      return 1;
    }
    PQclear(r);
    lat[i] = now_us() - start;
    total += lat[i];
  }
  qsort(lat, iters, sizeof(double), cmp_double);
  // Machine-readable: avg p50 p99 (microseconds)
  printf("%.0f %.0f %.0f\n", total / iters, lat[iters / 2], lat[(int)(iters * 0.99)]);
  PQfinish(conn);
  free(lat);
  return 0;
}
