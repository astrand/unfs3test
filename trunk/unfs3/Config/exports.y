%{
/*
 * UNFS3 exports parser and export controls
 * (C) 2004, Pascal Schmidt
 * see file LICENSE for license details
 */
#include "../config.h"

#include <rpc/rpc.h>
#include <limits.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "../nfs.h"
#include "../mount.h"
#include "../daemon.h"
#include "../backend.h"
#include "exports.h"

#ifndef PATH_MAX
# define PATH_MAX	4096
#endif

/* for lack of a better place */
#ifdef __GNUC__
#define U(x) x __attribute__ ((unused))
#else
#define U(x) x
#endif

/* lexer stuff, to avoid compiler warnings */
int yylex(void);
extern FILE *yyin;

/*
 * C code used by yacc parser
 */

typedef struct {
	char		orig[NFS_MAXPATHLEN];
	int		options;
        unsigned char   password[PASSWORD_MAXLEN+1];
        uint32          password_hash;
	struct in_addr	addr;
	struct in_addr	mask;
	struct e_host	*next;
} e_host;

typedef struct {
	char		path[NFS_MAXPATHLEN];
	char		orig[NFS_MAXPATHLEN];
	e_host		*hosts;
	uint32          fsid; /* export point fsid (for removables) */
	time_t          last_mtime; /* Last returned mtime (for removables) */
	uint32          dir_hash; /* Hash of dir contents (for removables) */
	struct e_item	*next;
} e_item;

/* export list, item, and host filled during parse */
static e_item *e_list = NULL;
static e_item cur_item;
static e_host cur_host;

/* mount protocol compatible variants */
static exports ne_list = NULL;
static struct exportnode ne_item;
static struct groupnode ne_host;

/* error status of last parse */
int e_error = FALSE;

/*
 * The FNV1a-32 hash algorithm
 * (http://www.isthe.com/chongo/tech/comp/fnv/)
 */
uint32 fnv1a_32(const char *str, uint32 hval)
{
    static const uint32 fnv_32_prime = 0x01000193;
    
    while (*str) {
	hval ^= *str++;
	hval *= fnv_32_prime;
    }
    return hval;
}

/*
 * get static fsid, for use with removable media export points
 */
static uint32 get_free_fsid(const char *path)
{
    uint32 hval;

    /* The 32:th bit is set to one on all special filehandles. The
       last 31 bits are hashed from the export point path. */
    hval = fnv1a_32(path, 0);
    hval |= 0x10000000UL;
    return hval;
}


/*
 * clear current host
 */
static void clear_host(void)
{
	memset(&cur_host, 0, sizeof(e_host));
	strcpy(cur_host.orig, "<anon clnt>");
	memset(&ne_host, 0, sizeof(struct groupnode));
}

/*
 * clear current item
 */
static void clear_item(void)
{
	memset(&cur_item, 0, sizeof(e_item));
	memset(&ne_item, 0, sizeof(struct exportnode));
}

/*
 * add current host to current export item
 */
static void add_host(void)
{
	e_host *new;
	e_host *iter;
	
	groups ne_new;
	groups ne_iter;

	new = malloc(sizeof(e_host));
	ne_new = malloc(sizeof(struct groupnode));
	if (!new || !ne_new) {
		logmsg(LOG_EMERG, "out of memory, aborting");
		daemon_exit(CRISIS);
	}

	*new = cur_host;
	*ne_new = ne_host;
	ne_new->gr_name = new->orig;

	/* internal list */
	if (cur_item.hosts) {
		iter = cur_item.hosts;
		while (iter->next)
			iter = (e_host *) iter->next;
		iter->next = (struct e_host *) new;
	} else
		cur_item.hosts = new;

	/* matching mount protocol list */
	if (ne_item.ex_groups) {
		ne_iter = ne_item.ex_groups;
		while (ne_iter->gr_next)
			ne_iter = (groups) ne_iter->gr_next;
		ne_iter->gr_next = ne_new;
	} else
		ne_item.ex_groups = ne_new;
	
	clear_host();
}

/*
 * add current item to current export list
 */
static void add_item(const char *path)
{
	char buf[PATH_MAX];
	e_item *new;
	e_item *iter;
	e_host *host;
	/* Is this item marked as removable for all hosts? */
	int removable_for_all = 1;
	
	exports ne_new;
	exports ne_iter;

	new = malloc(sizeof(e_item));
	ne_new = malloc(sizeof(struct exportnode));
	if (!new || !ne_new) {
		logmsg(LOG_EMERG, "out of memory, aborting");
		daemon_exit(CRISIS);
	}

	/* Loop over all hosts and check if marked as removable. */
	host = cur_item.hosts;
	while (host) {
		if (!(host->options & OPT_REMOVABLE))
			removable_for_all = 0;
		host = (e_host *) host->next;
	}

	if (removable_for_all) {
		/* If marked as removable for all hosts, don't try
		   realpath. */
		strncpy(buf, path, PATH_MAX);
	} else if (!backend_realpath(path, buf)) {
		logmsg(LOG_CRIT, "realpath for %s failed", path);
		e_error = TRUE;
		free(new);
		free(ne_new);
		clear_item();
		return;
	}

	if (strlen(buf) + 1 > NFS_MAXPATHLEN) {
		logmsg(LOG_CRIT, "attempted to export too long path");
		e_error = TRUE;
		free(new);
		free(ne_new);
		clear_item();
		return;
	}

	/* if no hosts listed, list default host */
	if (!cur_item.hosts)
		add_host();

	*new = cur_item;
	strcpy(new->path, buf);
	strcpy(new->orig, path);
	new->fsid = get_free_fsid(path);  
	new->last_mtime = 0;
	new->dir_hash = 0;

	*ne_new = ne_item;
	ne_new->ex_dir = new->orig;

	/* internal list */
	if (e_list) {
		iter = e_list;
		while (iter->next)
			iter = (e_item *) iter->next;
		iter->next = (struct e_item *) new;
	} else
		e_list = new;

	/* matching mount protocol list */
	if (ne_list) {
		ne_iter = ne_list;
		while (ne_iter->ex_next)
			ne_iter = (exports) ne_iter->ex_next;
		ne_iter->ex_next = ne_new;
	} else
		ne_list = ne_new;
		
	clear_item();
}

/*
 * fill current host's address given a hostname
 */
static void set_hostname(const char *name)
{
	struct hostent *ent;

	if (strlen(name) + 1 > NFS_MAXPATHLEN) {
		e_error = TRUE;
		return;
	}
	strcpy(cur_host.orig, name);

	ent = gethostbyname(name);

	if (ent) {
		memcpy(&cur_host.addr, ent->h_addr_list[0],
		       sizeof(struct in_addr));
		cur_host.mask.s_addr = ~0UL;
	} else {
		logmsg(LOG_CRIT, "could not resolve hostname '%s'", name);
		e_error = TRUE;
	}
}	

/*
 * fill current host's address given an IP address
 */
static void set_ipaddr(const char *addr)
{
	strcpy(cur_host.orig, addr);
	
	if (!inet_aton(addr, &cur_host.addr))
		e_error = TRUE;
	cur_host.mask.s_addr = ~0UL;
}

/*
 * compute network bitmask
 */
static unsigned long make_netmask(int bits) {
	unsigned long buf = 0;
	int i;

	for (i=0; i<bits; i++)
		buf = (buf << 1) + 1;
	for (; i < 32; i++)
		buf = (buf << 1);
	return htonl(buf);
}

/*
 * fill current host's address given IP address and netmask
 */
static void set_ipnet(char *addr, int new)
{
	char *pos, *net;

	pos = strchr(addr, '/');
	net = pos + 1;
	*pos = 0;
	
	set_ipaddr(addr);
	
	if (new)
		cur_host.mask.s_addr = make_netmask(atoi(net));
	else
		if (!inet_aton(net, &cur_host.mask))
			e_error = TRUE;

	*pos = '/';
	strcpy(cur_host.orig, addr);
}

/*
 * add an option bit to the current host
 */
static void add_option(const char *opt)
{
	if (strcmp(opt,"no_root_squash") == 0)
		cur_host.options |= OPT_NO_ROOT_SQUASH;
	else if (strcmp(opt,"root_squash") == 0)
		cur_host.options &= ~OPT_NO_ROOT_SQUASH;
	else if (strcmp(opt,"all_squash") == 0)
		cur_host.options |= OPT_ALL_SQUASH;
	else if (strcmp(opt,"no_all_sqash") == 0)
		cur_host.options &= ~OPT_ALL_SQUASH;
	else if (strcmp(opt,"rw") == 0)
		cur_host.options |= OPT_RW;
	else if (strcmp(opt,"ro") == 0)
		cur_host.options &= ~OPT_RW;
	else if (strcmp(opt,"removable") == 0)
		cur_host.options |= OPT_REMOVABLE;
	else if (strcmp(opt,"fixed") == 0)
		cur_host.options &= ~OPT_REMOVABLE;
	else if (strcmp(opt,"insecure") == 0)
		cur_host.options |= OPT_INSECURE;
	else if (strcmp(opt,"secure") == 0)
		cur_host.options &= ~OPT_INSECURE;
}

static void add_option_with_value(const char *opt, const char *val)
{
    if (strcmp(opt,"password") == 0) {
	if (strlen(val) > PASSWORD_MAXLEN) {
	    logmsg(LOG_WARNING, "Warning: password for export %s truncated to 64 chars",
		   cur_item.orig);
	}
	strncpy(cur_host.password, val, sizeof(password));
	cur_host.password[PASSWORD_MAXLEN] = '\0';
	/* Calculate hash */
	cur_host.password_hash = fnv1a_32(cur_host.password, 0);
    }
}

/*
 * dummy error function
 */
void yyerror(U(char *s))
{
	e_error = TRUE;
	return;
}

%}

%union {
	char text[NFS_MAXPATHLEN];
};

%token <text> PATH
%token <text> ID
%token <text> OPTVALUE
%token <text> WHITE
%token <text> IP
%token <text> NET
%token <text> OLDNET

%%

exports:
	export
	| export '\n' exports
	|
	;

export:
	PATH			{ add_item($1); }
	| PATH WHITE hosts	{ add_item($1); }
	| PATH WHITE		{ add_item($1); }
	;

hosts:
	host
	| host WHITE hosts
	| host WHITE
	;

host:
	name			{ add_host(); }
	| name '(' opts ')'	{ add_host(); }
	| '(' opts ')'		{ add_host(); }
	;

name:
	ID			{ set_hostname($1); }
	| IP			{ set_ipaddr($1); }
	| NET			{ set_ipnet($1, TRUE); }
	| OLDNET		{ set_ipnet($1, FALSE); }
	;
	
opts:
	opt			
	| opt ',' opts		
	|
	;
 
opt: 
	ID                      { add_option($1); }
        | ID OPTVALUE           { add_option_with_value($1,$2); } 
	;
%%

/*
 * C code using yacc parser + access code for exports list
 */

/* effective export list and access flag */
static e_item *export_list = NULL;
static volatile int exports_access = FALSE;

/* mount protocol compatible exports list */
exports exports_nfslist = NULL;

/*
 * free NFS groups list
 */
void free_nfsgroups(groups group)
{
	groups list, next;
	
	list = group;
	while (list) {
		next = (groups) list->gr_next;
		free(list);
		list = next;
	}
}

/*
 * free NFS exports list
 */
void free_nfslist(exports elist)
{
	exports list, next;

	list = elist;
	while(list) {
		next = (exports) list->ex_next;
		free_nfsgroups(list->ex_groups);
		free(list);
		list = next;
	}
}

/*
 * free list of host structures
 */
static void free_hosts(e_item *item)
{
	e_host *host, *cur;
	
	host = item->hosts;
	while (host) {
		cur = host;
		host = (e_host *) host->next;
		free(cur);
	}
}

/*
 * free list of export items
 */
static void free_list(e_item *item)
{
	e_item *cur;
	
	while (item) {
		free_hosts(item);
		cur = item;
		item = (e_item *) item->next;
		free(cur);
	}
}

/*
 * print out the current exports list (for debugging)
 */
void print_list(void)
{
	char addrbuf[16], maskbuf[16];

	e_item *item;
	e_host *host;
	
	item = e_list;
		
	while (item) {
		host = item->hosts;
		while (host) {
			/* inet_ntoa returns static buffer */
			strcpy(addrbuf, inet_ntoa(host->addr));
			strcpy(maskbuf, inet_ntoa(host->mask));
			printf("%s: ip %s mask %s options %i\n",
		       		item->path, addrbuf, maskbuf,
		       		host->options);
		       	host = (e_host *) host->next;
		}
		item = (e_item *) item->next;
	}
}

/*
 * clear current parse state
 */
static void clear_cur(void)
{
	e_list = NULL;
	ne_list = NULL;
	e_error = FALSE;
	clear_host();
	clear_item();
}

/*
 * parse an exports file
 */
void exports_parse(void)
{
	FILE *efile;

	/*
	 * if we are in the SIGHUP handler, a may_mount or get_options
	 * may currently be accessing the list
	 */
	if (exports_access) {
		logmsg(LOG_CRIT, "export list is being traversed, no reload\n");
		return;
	}

	efile = fopen(opt_exports, "r");
	if (!efile) {
		logmsg(LOG_CRIT, "could not open '%s', exporting nothing",
		       opt_exports);
		free_list(export_list);
		free_nfslist(exports_nfslist);
		export_list = NULL;
		exports_nfslist = NULL;
		return;
	}

	yyin = efile;
	clear_cur();
	yyparse();
	fclose(efile);
	
	if (e_error) {
		logmsg(LOG_CRIT, "syntax error in '%s', exporting nothing",
		       opt_exports);
		free_list(export_list);
		free_nfslist(exports_nfslist);
		export_list = NULL;
		exports_nfslist = NULL;
		return;
	}
	
	/* print out new list for debugging */
	if (!opt_detach)
		print_list();
	
	free_list(export_list);
	free_nfslist(exports_nfslist);
	export_list = e_list;
	exports_nfslist = ne_list;
}

/*
 * find a given host inside a host list, return options
 */
static int find_host(struct in_addr remote, e_item *item,
		     char **password, uint32 *password_hash)
{
	e_host *host;

	host = item->hosts;
	while (host) {
		if ((remote.s_addr & host->mask.s_addr) == host->addr.s_addr) {
			if (password != NULL) 
				*password = host->password;
			if (password_hash != NULL)
     			        *password_hash = host->password_hash;
			return host->options;
		}
		host = (e_host *) host->next;
	}
	return -1;
}

/* options cache */
int exports_opts = -1;
uint32 export_password_hash = 0;

/*
 * given a path, return client's effective options
 */
int exports_options(const char *path, struct svc_req *rqstp,
		    char **password, uint32 *fsid)
{
	e_item *list;
	struct in_addr remote;
	unsigned int last_len = 0;
	int cur_opts;
	
	exports_opts = -1;

	/* check for client attempting to use invalid pathname */
	if (!path || strstr(path, "/../"))
		return exports_opts;
	
	remote = get_remote(rqstp);

	/* protect against SIGHUP reloading the list */
	exports_access = TRUE;
	
	list = export_list;
	while (list) {
		/* longest matching prefix wins */
		if (strlen(list->path) > last_len    &&
		    strstr(path, list->path) == path) {
			cur_opts = find_host(remote, list, password, &export_password_hash);
			if (fsid != NULL)
				*fsid = list->fsid;
			if (cur_opts != -1) {
				exports_opts = cur_opts;
				last_len = strlen(list->path);
			}
		}
		list = (e_item *) list->next;
	}
	exports_access = FALSE;
	return exports_opts;
}

/*
 * check whether path is an export point
 */
int export_point(const char *path)
{
        e_item *list;

	exports_access = TRUE;
	list = export_list;

	while (list) {
	    if (strcmp(path, list->path) == 0) {
		exports_access = FALSE;
		return TRUE;
	    }
	    list = (e_item *) list->next;
	}
	exports_access = FALSE;
	return FALSE;
}

/*
 * return exported path from static fsid
 */
char *export_point_from_fsid(uint32 fsid, time_t **last_mtime, uint32 **dir_hash)
{
    e_item *list;
    
    exports_access = TRUE;
    list = export_list;
    
    while (list) {
	if (list->fsid == fsid) {
	    if (last_mtime != NULL)
		*last_mtime = &list->last_mtime;
	    if (dir_hash != NULL)
		*dir_hash = &list->dir_hash;
	    exports_access = FALSE;
	    return list->path;
	}
	list = (e_item *) list->next;
    }
    exports_access = FALSE;
    return NULL;
}


/*
 * check whether export options of a path match with last set of options
 */
nfsstat3 exports_compat(const char *path, struct svc_req *rqstp)
{
	int prev;
	
	prev = exports_opts;
	if (exports_options(path, rqstp, NULL, NULL) == prev)
		return NFS3_OK;
	else if (exports_opts == -1)
		return NFS3ERR_ACCES;
	else
		return NFS3ERR_XDEV;
}

/*
 * check whether options indicate rw mount
 */
nfsstat3 exports_rw(void)
{
	if (exports_opts != -1 && (exports_opts & OPT_RW))
		return NFS3_OK;
	else
		return NFS3ERR_ROFS;
}
