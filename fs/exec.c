/*
 *  linux/fs/exec.c
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * #!-checking implemented by tytso.
 */

/*
 * Demand-loading implemented 01.12.91 - no need to read anything but
 * the header into memory. The inode of the executable is put into
 * "current->executable", and page faults do the actual loading. Clean.
 *
 * Once more I can proudly say that linux stood up to being changed: it
 * was less than 2 hours work to get demand-loading completely implemented.
 */

#include <signal.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <a.out.h>

#include <linux/fs.h>
#include <linux/sched.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <asm/segment.h>

extern int sys_exit(int exit_code);
extern int sys_close(int fd);

/*
 * MAX_ARG_PAGES defines the number of pages allocated for arguments
 * and envelope for the new program. 32 should suffice, this gives
 * a maximum env+arg of 128kB !
 */
#define MAX_ARG_PAGES 32

int sys_uselib(const char * library)
{
	struct m_inode * inode;
	unsigned long base;

	if (get_limit(0x17) != TASK_SIZE)
		return -EINVAL;
	if (library) {
		if (!(inode=namei(library)))		/* get library inode */
			return -ENOENT;
	} else
		inode = NULL;
/* we should check filetypes (headers etc), but we don't */
	iput(current->library);
	current->library = NULL;
	base = get_base(current->ldt[2]);
	base += LIBRARY_OFFSET;
	free_page_tables(base,LIBRARY_SIZE);
	current->library = inode;
	return 0;
}

/*
 * create_tables() parses the env- and arg-strings in new user
 * memory and creates the pointer tables from them, and puts their
 * addresses on the "stack", returning the new stack pointer value.
 */
static unsigned long * create_tables(char * p,int argc,int envc)
{
	unsigned long *argv,*envp;
	unsigned long * sp;

	sp = (unsigned long *) (0xfffffffc & (unsigned long) p);
	sp -= envc+1;
	envp = sp;
	sp -= argc+1;
	argv = sp;
	put_fs_long((unsigned long)envp,--sp);
	put_fs_long((unsigned long)argv,--sp);
	put_fs_long((unsigned long)argc,--sp);
	while (argc-->0) {
		put_fs_long((unsigned long) p,argv++);
		while (get_fs_byte(p++)) /* nothing */ ;
	}
	put_fs_long(0,argv);
	while (envc-->0) {
		put_fs_long((unsigned long) p,envp++);
		while (get_fs_byte(p++)) /* nothing */ ;
	}
	put_fs_long(0,envp);
	return sp;
}

/*
 * count() counts the number of arguments/envelopes
 */
static int count(char ** argv)
{
	int i=0;
	char ** tmp;

	if (tmp = argv)
		while (get_fs_long((unsigned long *) (tmp++)))
			i++;

	return i;
}

/*
 * 'copy_string()' copies argument/envelope strings from user
 * memory to free pages in kernel mem. These are in a format ready
 * to be put directly into the top of new user memory.
 *
 * Modified by TYT, 11/24/91 to add the from_kmem argument, which specifies
 * whether the string and the string array are from user or kernel segments:
 * 
 * from_kmem     argv *        argv **
 *    0          user space    user space
 *    1          kernel space  user space
 *    2          kernel space  kernel space
 * 
 * We do this by playing games with the fs segment register.  Since it
 * it is expensive to load a segment register, we try to avoid calling
 * set_fs() unless we absolutely have to.
 */
static unsigned long copy_strings(int argc,char ** argv,unsigned long *page,
		unsigned long p, int from_kmem)
{
	char *tmp, *pag;
	int len, offset = 0;
	unsigned long old_fs, new_fs;

	if (!p)
		return 0;	/* bullet-proofing */
	new_fs = get_ds();
	old_fs = get_fs();
	if (from_kmem==2)
		set_fs(new_fs);
	while (argc-- > 0) {
		if (from_kmem == 1)
			set_fs(new_fs);
		if (!(tmp = (char *)get_fs_long(((unsigned long *)argv)+argc)))
			panic("argc is wrong");
		if (from_kmem == 1)
			set_fs(old_fs);
		len=0;		/* remember zero-padding */
		do {
			len++;
		} while (get_fs_byte(tmp++));
		if (p-len < 0) {	/* this shouldn't happen - 128kB */
			set_fs(old_fs);
			return 0;
		}
		while (len) {
			--p; --tmp; --len;
			if (--offset < 0) {
				offset = p % PAGE_SIZE;
				if (from_kmem==2)
					set_fs(old_fs);
				if (!(pag = (char *) page[p/PAGE_SIZE]) &&
				    !(pag = (char *) page[p/PAGE_SIZE] =
				      (unsigned long *) get_free_page())) 
					return 0;
				if (from_kmem==2)
					set_fs(new_fs);

			}
			*(pag + offset) = get_fs_byte(tmp);
		}
	}
	if (from_kmem==2)
		set_fs(old_fs);
	return p;
}

static unsigned long change_ldt(unsigned long text_size,unsigned long * page)
{
	unsigned long code_limit,data_limit,code_base,data_base;
	int i;

	code_limit = TASK_SIZE;
	data_limit = TASK_SIZE;
	code_base = get_base(current->ldt[1]);
	data_base = code_base;
	set_base(current->ldt[1],code_base);
	set_limit(current->ldt[1],code_limit);
	set_base(current->ldt[2],data_base);
	set_limit(current->ldt[2],data_limit);
/* make sure fs points to the NEW data segment */
	__asm__("pushl $0x17\n\tpop %%fs"::);
	data_base += data_limit - LIBRARY_SIZE;
	for (i=MAX_ARG_PAGES-1 ; i>=0 ; i--) {
		data_base -= PAGE_SIZE;
		if (page[i])
			put_dirty_page(page[i],data_base);
	}
	return data_limit;
}

/*
 * 'do_execve()' executes a new program.
 *
 * NOTE! We leave 4MB free at the top of the data-area for a loadable
 * library.
 */
/*
 * 注意：我们在数据区顶部保留4MB空闲空间给可加载库代码
 */
// execve()系统调用终端调用函数。加载并执行子进程（其他程序）
// 该函数的参数是进入系统调用处理过程后直到调用本系统调用处理过程
// 和调用本函数之前逐步压入栈中的值。这些在system_call.s文件之中的值包括：
// (1) edx、ecx和ebx寄存器值，分别对应**envp、**argv和**filename
// (2) 调用sys_call_table中的sys_execve函数时压入栈的函数返回地址
// (3) 在调用本函数do_execve前入栈的指向栈中调用系统中断的程序代码指针eip
// 参数：eip - 调用系统中断的程序代码指针；tmp - 系统中断中调用 sys_execve 时的返回地址； 
// 		filename - 被执行程序文件名指针；argv - 命令行参数指针数组的指针； 
// 		envp - 环境变量指针数组的指针。 
// 返回：如果调用成功，则不返回；否则设置出错号，并返回-1。
int do_execve(unsigned long * eip,long tmp,char * filename,
	char ** argv, char ** envp)
{
	struct m_inode * inode;
	struct buffer_head * bh;
	struct exec ex;
	unsigned long page[MAX_ARG_PAGES];			// 参数和环境串空间页面指针数组
	int i,argc,envc;
	int e_uid, e_gid;							// 有效用户ID和有效组ID
	int retval;
	int sh_bang = 0;							// 控制是否需要执行脚本程序
	unsigned long p=PAGE_SIZE*MAX_ARG_PAGES-4;	// p指向参数和环境空间的最后部分

// 在正式设置执行文件的运行环境之前，让我们先做些准备工作。内核准备了 128KB（32 个页面） 
// 空间来存放化执行文件的命令行参数和环境字符串。上行把 p 初始设置成位于 128KB 空间的最后 
// 1 个长字处。在初始参数和环境空间的操作过程中，p 将用来指明在 128KB 空间中的当前位置。 
// 另外，参数 eip[1]是调用本次系统调用的原用户程序代码段寄存器 CS 值，其中的段选择符当然 
// 必须是当前任务的代码段选择符（0x000f）。 若不是该值，那么 CS 只能会是内核代码段的选择 
// 符 0x0008。 但这是绝对不允许的，因为内核代码是常驻内存而不能被替换掉的。因此下面根据 
// eip[1]的值确认是否符合正常情况。然后再初始化 128KB 的参数和环境串空间，把所有字节清零， 
// 并取出执行文件的 i 节点。再根据函数参数分别计算出命令行参数和环境字符串的个数 argc 和 
// envc。另外，执行文件必须是常规文件。
	if ((0xffff & eip[1]) != 0x000f)
		panic("execve called from supervisor mode");
	for (i=0 ; i<MAX_ARG_PAGES ; i++)	/* clear page-table */
		page[i]=0;
	if (!(inode=namei(filename)))		/* get executables inode */
		return -ENOENT;
	argc = count(argv);					// 命令行参数个数
	envc = count(envp);			// 环境字符串变量个数
	
restart_interp:
	if (!S_ISREG(inode->i_mode)) {	/* must be regular file */
		retval = -EACCES;
		goto exec_error2;				// 若不是常规文件则置出错码，并跳转到错误处理逻辑
	}
// 下面检查当前进程是否有权运行指定的执行文件。即根据执行文件 i 节点中的属性，看看本进程 
// 是否有权执行它。在把执行文件 i 节点的属性字段值取到 i 中后，我们首先查看属性中是否设置 
// 了“设置-用户-ID”（set-user_id）标志 和“设置-组-ID”（set-group-id）标志。这两个 
// 标志主要用于让一般用户能够执行特权用户（如超级用户 root）的程序，例如改变密码的程序 
// passwd 等。 如果 set-user-id 标志置位，则后面执行进程的有效用户 ID（euid）就设置成执行 
// 文件的用户 ID，否则设置成当前进程的 euid。如果执行文件 set-group-id 被置位的话，则执行 
// 进程的有效组 ID（egid）就设置为执行文件的组 ID，否则设置成当前进程的 egid。这里暂时把 
// 这两个判断出来的值保存在变量 e_uid 和 e_gid 中。
	i = inode->i_mode;
	e_uid = (i & S_ISUID) ? inode->i_uid : current->euid;
	e_gid = (i & S_ISGID) ? inode->i_gid : current->egid;
// 现在根据进程的 euid 和 egid 与执行文件的访问属性进行比较。如果执行文件属于运行进程的用 
// 户，则把文件属性值 i 右移 6 位，此时其最低 3 位是文件宿主的访问权限标志。否则的话如果执 
// 行文件与当前进程的用户属于同组，则使属性值最低 3 位是执行文件组用户的访问权限标志。否 
// 则此时属性字最低 3 位就是其他用户访问该执行文件的权限。 
//
// 然后我们根据该最低 3 比特值来判断当前进程是否有权限运行这个执行文件。如果选出的相应用 
// 户没有运行改文件的权力（位 0 是执行权限），并且其他用户也没有任何权限或者当前进程用户 
// 不是超级用户，则表明当前进程没有权力运行这个执行文件。于是置不可执行出错码，并跳转到 
// exec_error2 处去作退出处理。
	if (current->euid == inode->i_uid)		// 检查当前进程的有效用户ID是否与文件的所有者相同
		i >>= 6;
	else if (in_group_p(inode->i_gid))		// 检查当前进程的有效组ID是否与文件的组ID相同
		i >>= 3;
											// 什么都不操作，此时最低3位就是其他用户执行权限
	if (!(i & 1) &&	// 检查i的最低位（也就是执行权限位），如果为0则表示当前用户没有执行该文件的权限
	    !((inode->i_mode & 0111) && suser())) {	// 检查是不是超级用户
		retval = -ENOEXEC;
		goto exec_error2;
	}
// 若程序能执行到这里，说明当前进程有运行指定执行文件的权限。因此从这里开始我们需要取出 
// 执行文件首部的数据，并根据其中的信息来分析设置运行环境，或者运行另一个 shell 程序来执 
// 行脚本程序。首先读取执行文件的第一块数据到高速缓冲块中，并复制缓冲块数据到 ex 结构中。 
// 如果执行文件开始的两个字节是字符'#!'，则说明执行文件是一个脚本文本文件。若要运行脚本 
// 文件，我们就需要执行脚本文件的解释程序（例如 shell 程序）。通常脚本文件的第一行文本均 
// 为 “#！/bin/bash”，它指明了运行脚本文件需要的解释程序。 运行方法是从脚本文件第一行 
// （带字符'#!'）中取出其中的解释程序名及后面的参数（若有的话），然后将这些参数和脚本文 
// 件名放进执行文件（此时是解释程序）的命令行参数空间中。在这之前我们当然需要先把函数指 
// 定的原有命令行参数和环境字符串放到 128KB 空间中，而这里建立起来的命令行参数则放到它们 
// 前面位置处（因为是逆向放置）。最后让内核执行脚本文件的解释程序。下面就是在设置好解释 
// 程序的脚本文件名等参数后，取出解释程序的 i 节点并跳转去执行解释程序。由于我们 
// 需要跳转到执行过的代码中去，因此在确认并处理了脚本文件之后需要设置一个禁止再次执 
// 行下面的脚本处理代码标志 sh_bang。 在后面的代码中该标志也用来表示我们已经设置好执行文 
// 件的命令行参数，不要重复设置。
	if (!(bh = bread(inode->i_dev,inode->i_zone[0]))) {
		retval = -EACCES;
		goto exec_error2;
	}
	ex = *((struct exec *) bh->b_data);	/* read exec-header */
	if ((bh->b_data[0] == '#') && (bh->b_data[1] == '!') && (!sh_bang)) {
		/*
		 * This section does the #! interpretation.
		 * Sorta complicated, but hopefully it will work.  -TYT
		 */

		char buf[128], *cp, *interp, *i_name, *i_arg;
		unsigned long old_fs;

		strncpy(buf, bh->b_data+2, 127);
		brelse(bh);
		iput(inode);
		buf[127] = '\0';
		if (cp = strchr(buf, '\n')) {
			*cp = '\0';
			for (cp = buf; (*cp == ' ') || (*cp == '\t'); cp++);
		}
		if (!cp || *cp == '\0') {
			retval = -ENOEXEC; /* No interpreter name found */
			goto exec_error1;
		}
		interp = i_name = cp;
		i_arg = 0;
		for ( ; *cp && (*cp != ' ') && (*cp != '\t'); cp++) {
 			if (*cp == '/')
				i_name = cp+1;
		}
		if (*cp) {
			*cp++ = '\0';
			i_arg = cp;
		}
		/*
		 * OK, we've parsed out the interpreter name and
		 * (optional) argument.
		 */
		if (sh_bang++ == 0) {
			p = copy_strings(envc, envp, page, p, 0);
			p = copy_strings(--argc, argv+1, page, p, 0);
		}
		/*
		 * Splice in (1) the interpreter's name for argv[0]
		 *           (2) (optional) argument to interpreter
		 *           (3) filename of shell script
		 *
		 * This is done in reverse order, because of how the
		 * user environment and arguments are stored.
		 */
		p = copy_strings(1, &filename, page, p, 1);
		argc++;
		if (i_arg) {
			p = copy_strings(1, &i_arg, page, p, 2);
			argc++;
		}
		p = copy_strings(1, &i_name, page, p, 2);
		argc++;
		if (!p) {
			retval = -ENOMEM;
			goto exec_error1;
		}
		/*
		 * OK, now restart the process with the interpreter's inode.
		 */
		old_fs = get_fs();
		set_fs(get_ds());
		if (!(inode=namei(interp))) { /* get executables inode */
			set_fs(old_fs);
			retval = -ENOENT;
			goto exec_error1;
		}
		set_fs(old_fs);
		goto restart_interp;
	}
// 此时缓冲块中的执行文件头结构数据已经复制到了 ex 中。于是先释放该缓冲块，并开始对 ex 
// 中的执行头信息进行判断处理。对于这个内核来说，它仅支持 ZMAGIC 执行文件格式，并且执行 
// 文件代码都从逻辑地址 0 开始执行，因此不支持含有代码或数据重定位信息的执行文件。当然， 
// 如果执行文件实在太大或者执行文件残缺不全，那么我们也不能运行它。因此对于下列情况将不 
// 执行程序：执行文件不是可执行文件（ZMAGIC）、或者代码和数据重定位部分长度不等于 0、或者 
// (代码段 + 数据段 + 堆)长度超过 50MB、 或者执行文件长度小于 (代码段 + 数据段 + 符号表 
// 长度 + 执行头部分) 长度的总和，这部分的信息可以从之前读取到的文件头之中获得。
	brelse(bh);
	if (N_MAGIC(ex) != ZMAGIC || ex.a_trsize || ex.a_drsize ||
		ex.a_text+ex.a_data+ex.a_bss>0x3000000 ||
		inode->i_size < ex.a_text+ex.a_data+ex.a_syms+N_TXTOFF(ex)) {
		retval = -ENOEXEC;
		goto exec_error2;
	}
	if (N_TXTOFF(ex) != BLOCK_SIZE) {
		printk("%s: N_TXTOFF != BLOCK_SIZE. See a.out.h.", filename);
		retval = -ENOEXEC;
		goto exec_error2;
	}
	if (!sh_bang) {
		p = copy_strings(envc,envp,page,p,0);
		p = copy_strings(argc,argv,page,p,0);
		if (!p) {
			retval = -ENOMEM;
			goto exec_error2;
		}
	}
/* OK, This is the point of no return */
/* note that current->library stays unchanged by an exec */
	if (current->executable)
		iput(current->executable);
	current->executable = inode;
	current->signal = 0;
	for (i=0 ; i<32 ; i++) {
		current->sigaction[i].sa_mask = 0;
		current->sigaction[i].sa_flags = 0;
		if (current->sigaction[i].sa_handler != SIG_IGN)
			current->sigaction[i].sa_handler = NULL;
	}
	for (i=0 ; i<NR_OPEN ; i++)
		if ((current->close_on_exec>>i)&1)
			sys_close(i);
	current->close_on_exec = 0;
	free_page_tables(get_base(current->ldt[1]),get_limit(0x0f));
	free_page_tables(get_base(current->ldt[2]),get_limit(0x17));
	if (last_task_used_math == current)
		last_task_used_math = NULL;
	current->used_math = 0;
	p += change_ldt(ex.a_text,page);
	p -= LIBRARY_SIZE + MAX_ARG_PAGES*PAGE_SIZE;
	p = (unsigned long) create_tables((char *)p,argc,envc);
	current->brk = ex.a_bss +
		(current->end_data = ex.a_data +
		(current->end_code = ex.a_text));
	current->start_stack = p & 0xfffff000;
	current->suid = current->euid = e_uid;
	current->sgid = current->egid = e_gid;
	eip[0] = ex.a_entry;		/* eip, magic happens :-) */
	eip[3] = p;			/* stack pointer */
	return 0;
exec_error2:
	iput(inode);
exec_error1:
	for (i=0 ; i<MAX_ARG_PAGES ; i++)
		free_page(page[i]);
	return(retval);
}
