/*
 * UNFS3 low-level filehandle routines
 * (C) 2004, Pascal Schmidt <der.eremit@email.de>
 * see file LICENSE for license details
 */

#ifndef UNFS3_FH_H
#define UNFS3_FH_H

/* minimum length of complete filehandle */
#define FH_MINLEN 3

/* maximum depth of pathname described by filehandle */
#define FH_MAXLEN 50


typedef struct {
    uint32                  dev;
    uint32                  ino;
    uint32                  gen;
    unsigned char   inos[FH_MAXLEN];
} __attribute__((packed)) unfs3_fh_devino_t;

typedef struct {
        unsigned char   flags;
        unsigned char   len; /* Length of path or dih.inos */
    union {
        unsigned char   path[NFS3_FHSIZE-2]; /* For ascii-path FHs */
	unfs3_fh_devino_t dih;               /* For dev-ino-hash FHs */
    };
} __attribute__((packed)) unfs3_fh_t;


#define FH_ANY 0
#define FH_DIR 1

#define FHTYPE_DEV_INO_HASH   0x0
#define FHTYPE_ASCII_PATH     0x1

#define FD_NONE (-1)			/* used for get_gen */

extern int st_cache_valid;		/* stat value is valid */
extern struct stat st_cache;	/* cached stat value */

uint32 get_gen(struct stat obuf, int fd, const char *path);

int nfh_valid(nfs_fh3 fh);
int fh_valid(unfs3_fh_t fh);

unfs3_fh_t fh_comp_raw(const char *path, int need_dir);
char *fh_get_ascii_path(unfs3_fh_t *fh);
unfs3_fh_t fh_comp_ascii(const char *path, int need_dir);
u_int fh_len(const unfs3_fh_t *fh);

unfs3_fh_t *fh_extend(nfs_fh3 fh, uint32 dev, uint32 ino, uint32 gen);
post_op_fh3 fh_extend_post(nfs_fh3 fh, uint32 dev, uint32 ino, uint32 gen);
post_op_fh3 fh_extend_type(nfs_fh3 fh, const char *path, unsigned int type);

char *fh_decomp_raw(const unfs3_fh_t *fh);

#endif
