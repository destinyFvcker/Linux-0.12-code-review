/*
 *  linux/mm/memory.c
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * demand-loading started 01.12.91 - seems it is high on the list of
 * things wanted, and it should be easy to implement. - Linus
 */

/*
 * Ok, demand-loading was easy, shared pages a little bit tricker. Shared
 * pages started 02.12.91, seems to work. - Linus.
 *
 * Tested sharing by executing about 30 /bin/sh: under the old kernel it
 * would have taken more than the 6M I have free, but it worked well as
 * far as I could see.
 *
 * Also corrected some "invalidate()"s - I wasn't doing enough of them.
 */

/*
 * Real VM (paging to/from disk) started 18.12.91. Much more work and
 * thought has to go into this. Oh, well..
 * 19.12.91  -  works, somewhat. Sometimes I get faults, don't know why.
 *		Found it. Everything seems to work now.
 * 20.12.91  -  Ok, making the swap-device changeable like the root.
 */

#include <signal.h>			// 信号头文件，定义信号符号常量，信号结构及信号函数原型

#include <asm/system.h>		// 系统头文件，定义设置或修改描述符/中断门等嵌入汇编宏

#include <linux/sched.h>	// 调度程序头文件，定义任务结构task_struct、任务0的数据
#include <linux/head.h>		// head头文件，定义段描述符的简单结构，和几个选择符常量
#include <linux/kernel.h>	// 内核头文件，含有一些内核常用函数的原型定义

// 该宏用于判断给定线性地址是否位于当前进程的代码段范围内
// (((addr)+4095)&~4095) 用于取得线性地址addr所在内存页面的末端地址
// 首先，将地址加上4095(0xFFF)的目的就是确保即使addr在页面的中间或开头，他也会被推进到
// 页面的末端或超出页面的末端
// ~ 是按位取反的意思，4095按位取反相当于将低12位全部清零的一个掩码
#define CODE_SPACE(addr) ((((addr)+4095)&~4095) < \
current->start_code + current->end_code)

unsigned long HIGH_MEMORY = 0;	// 全局变量，存放实际物理内存最高地址处

// 关于为什么下面会有两个冒号::，因为这里没有输出寄存器
#define copy_page(from,to) \
__asm__("cld ; rep ; movsl"::"S" (from),"D" (to),"c" (1024):"cx","di","si")

// 物理内存映射字节图（1 字节代表 1 页内存）。每个页面对应的字节用于标志页面当前被引用 
// （占用）次数。对于含有 16MB 物理内存的机器，它最大可以映射 15Mb 的内存空间。在初始化 
// 函数mem_init()中，对于不能用作主内存区页面的位置均都预先被设置成 USED（100）。
unsigned char mem_map [ PAGING_PAGES ] = {0,};

/*
 * Free a page of memory at physical address 'addr'. Used by
 * 'free_page_tables()'
 */
// 注意这里是“物理地址”!
// 释放物理地址 addr 开始的 1 页面内存。 
// 物理地址 1MB 以下的内存空间用于内核程序和缓冲，不能被作为分配页面的内存空间。因此 
// 参数 addr 需要大于 1MB。
void free_page(unsigned long addr)
{
// 首先判断参数给定的物理地址 addr 的合理性。如果物理地址 addr 小于内存低端（1MB），则表 
// 示在内核程序或高速缓冲中，对此不予处理；如果物理地址 addr >= 系统所含物理内存最高端， 
// 则显示出错信息并且内核停止工作。
  if (addr < LOW_MEM)	// LOW_MEM = 1MB, 定义在 include/linux/mm.h 中。
    return;
  if (addr >= HIGH_MEMORY)
    panic("trying to free nonexistent page");
// 如果对参数 addr 验证通过，那么就根据这个物理地址换算出从内存低端开始计起的内存页面号。 
// 页面号 = (addr – LOW_MEM)/4096。可见页面号从 0 号开始计起。此时 addr 中存放着页面号。 
// 如果该页面号对应的页面映射字节不等于 0，则减 1 返回。此时该映射字节值应该为 0，表示页
// 面已释放。如果对应页面字节原本就是0，表示该物理页面本来就是空闲的，说明内核代码出问
// 题。于是显示出错信息并停机。
  addr -= LOW_MEM;
  addr >>= 12;
  if (mem_map[addr]--)
    return;
  mem_map[addr] = 0;
  panic("trying to free free page");
}

/*
 * This function frees a continuos block of page tables, as needed
 * by 'exit()'. As does copy_page_tables(), this handles only 4Mb blocks.
 */
// 根据指定的线性地址和限长（页表个数），释放内存块并置表项空闲。 
// 页目录表位于物理地址 0 开始处，共 1024 项，每项 4 字节，共占 4K 字节。每个目录项指定一个 
// 页表。内核页表从物理地址 0x1000 处开始（紧接着目录空间），共 4 个页表。每个页表有 1024 
// 项，每项 4 字节。因此也占 4K（1 页）内存。除了在内核代码中的进程 0 和 1 以外，其它各进程 
// 的页表所占据的页面在进程被创建时由内核为其在主内存区申请得到。每个页表项对应 1 页物理 
// 内存，因此一个页表最多可映射 4MB 的物理内存.
// 
// 因为这里是在free_page_table，所以会以一个页表可以管理的物理内存大小-4Mb为粒度来进行释放
// 实际上管理的是页目录表了
//
// 参数：from - 起始线性基地址；size - 释放的字节长度。
int free_page_tables(unsigned long from,unsigned long size)
{
	unsigned long *pg_table;
	unsigned long * dir, nr;

// 首先检测参数 from 给出的线性基地址是否在 4MB 的边界处，因为该函数只能处理这种情况。 
// 若 from = 0，则出错。说明试图释放内核和缓冲所占空间。 
// 然后计算参数 size 给出的长度所占的页目录项数（4MB 的进位整数倍），也即所占页表数。因为 
// 1 个页表可管理 4MB 物理内存，所以这里用右移 22 位的方式把需要复制的内存长度值除以 4MB。 
// 其中加上 0x3fffff（即 4Mb -1）用于得到进位整数倍结果，即除操作若有余数则进 1。例如，如 
// 果原 size = 4.01Mb，那么可得到结果 size = 2。接着计算给出的线性基地址对应的起始目录项。 
// 对应的目录项号等于 from >> 20。因为每项占 4 字节，并且由于页目录表从物理地址 0 开始存放， 
// 因此实际目录项指针= 目录项号<<2，也即(from>>20)。“与”上 0xffc 确保目录项指针范围有效。
	if (from & 0x3fffff)
		panic("free_page_tables called with wrong alignment");
	if (!from)
		panic("Trying to free up swapper memory space");

	size = (size + 0x3fffff) >> 22;
	// 首先将from右移20位，这是因为线性地址的高10位用于索引表中的某一项
	// 0xffc = 0b1111_1111_1100，也就是说这里保存了剩下12位的高0位，并且这里正好
	// 将地址对齐到了4字节边界，这样就可以正确进行指针的转换
	dir = (unsigned long *) ((from>>20) & 0xffc); /* _pg_dir = 0 */

// 此时 size 是释放的页表个数，即页目录项数，而 dir 是起始目录项指针。现在对页目录项开始 
// 循环操作，依次释放每个页表中的页表项。如果当前目录项无效（P 位=0），表示该目录项没有 
// 使用（对应的页表不存在），则继续处理下一个目录项。否则从目录项中取出页表地址 pg_table， 
// 并对该页表中的 1024 个表项进行处理，释放有效页表项（P 位=1）对应的物理内存页面，或者 
// 从交换设备中释放无效页表项（P 位=0）对应的页面，即释放交换设备中对应的内存页面（因为 
// 页面可能已经交换出去）。然后把该页表项清零，并继续处理下一页表项。当一个页表所有表项 
// 都处理完毕就释放该页表自身占据的内存页面，并继续处理下一页目录项。最后刷新页变换高速 
// 缓冲，并返回 0。
	for ( ; size-->0 ; dir++) {
		if (!(1 & *dir))	// 检查是否当前目录项无效（P位 = 0）
			continue;
		pg_table = (unsigned long *) (0xfffff000 & *dir);	// 取页表地址
		for (nr=0 ; nr<1024 ; nr++) {
			if (*pg_table) {								// 若所指页表项内容不为0
				if (1 & *pg_table)							// 若该项有效，则释放对应页
					free_page(0xfffff000 & *pg_table);
				else										// 否则释放交换设备中的对应项
					swap_free(*pg_table >> 1);
				*pg_table = 0;								// 将页表项内容清零
			}
			pg_table++;										// 指向页表之中的下一项
		}
		free_page(0xfffff000 & *dir);					// 释放该页表所占内存页面
		*dir = 0;											// 对应页表的目录项清零
	}
	invalidate();											// 刷新CPU页变换高速缓冲
	return 0;
}

/*
 *  Well, here is one of the most complicated functions in mm. It
 * copies a range of linerar addresses by copying only the pages.
 * Let's hope this is bug-free, 'cause this one I don't want to debug :-)
 *
 * Note! We don't copy just any chunks of memory - addresses have to
 * be divisible by 4Mb (one page-directory entry), as this makes the
 * function easier. It's used only by fork anyway.
 *
 * NOTE 2!! When from==0 we are copying kernel space for the first
 * fork(). Then we DONT want to copy a full page-directory entry, as
 * that would lead to some serious memory waste - we just copy the
 * first 160 pages - 640kB. Even that is more than we need, but it
 * doesn't take any more memory - we don't copy-on-write in the low
 * 1 Mb-range, so the pages can be shared with the kernel. Thus the
 * special case for nr=xxxx.
 */
// 复制页目录表项和页表项。
// 复制指定线性地址和长度内存对应的页目录项和页表项，从而被复制的页目录和页表对应的原物
// 理内存页面区被两套页表映射而共享使用。在复制时，需申请新页面来存放新页表，原物理内存
// 区将被共享。此后两个进程（父进程和其子进程）将共享内存区，直到有一个进程执行写操作时，
// 内核才会为写操作进程分配新的内存页（写时复制机制）。
// 参数 from、to 是线性地址，size 是需要复制（共享）的内存长度，单位是字节。
int copy_page_tables(unsigned long from,unsigned long to,long size)
{
	unsigned long * from_page_table;
	unsigned long * to_page_table;
	unsigned long this_page;
	unsigned long * from_dir, * to_dir;
	unsigned long new_page;
	unsigned long nr;

// 首先检测参数给出的源地址 from 和目的地址 to 的有效性。源地址和目的地址都需要在 4Mb 内存 
// 边界地址上。作这样的要求是因为一个页表的 1024 项可管理 4Mb 内存。源地址 from 和目的地址 
// to 只有满足这个要求才能保证从一个页表的第 1 项开始复制页表项，并且新页表的最初所有项都 
// 是有效的。然后取得源地址和目的地址的起始目录项指针（from_dir 和 to_dir）。再根据参数给 
// 出的长度 size 计算要复制的内存块占用的页表数（即目录项数）。
	if ((from&0x3fffff) || (to&0x3fffff))
		panic("copy_page_tables called with wrong alignment");
	from_dir = (unsigned long *) ((from>>20) & 0xffc); /* _pg_dir = 0 */
	to_dir = (unsigned long *) ((to>>20) & 0xffc);
	size = ((unsigned) (size+0x3fffff)) >> 22;
	for( ; size-->0 ; from_dir++,to_dir++) {
		if (1 & *to_dir)
			panic("copy_page_tables: already exist");
		if (!(1 & *from_dir))
			continue;
// 在验证了当前源目录项和目的项正常之后，我们取源目录项中页表地址 from_page_table。 
// 为了保存目的目录项对应的页表，需要在主内存区中申请 1 页空闲内存页。如果取空闲页面 
// 函数 get_free_page() 返回 0，则说明没有申请到空闲内存页面，可能是内存不够。于是返 
// 回-1 值退出。
		from_page_table = (unsigned long *) (0xfffff000 & *from_dir);
		if (!(to_page_table = (unsigned long *) get_free_page()))
			return -1;	/* Out of memory, see freeing */
// 随后我们设置目的目录项信息：把最后 3 位置位，即当前目的目录项“或”上 7，表示对应 
// 页表映射的内存页面是用户级的，并且可读写、存在（Usr, R/W, Present）。 （如果 U/S 
// 位是 0，则 R/W 就没有作用。如果 U/S 是 1，而 R/W 是 0，那么运行在用户层的代码就只能 
// 读页面。如果 U/S 和 R/W 都置位，则就有读写的权限）。然后针对当前处理的页目录项对应 
// 的页表，设置需要复制的页面项数。如果是在内核空间，则仅需复制头 160 页对应的页表项 
// （nr= 160），对应于开始 640KB 物理内存。否则需要复制一个页表中的所有 1024 个页表项 
// （nr= 1024），可映射 4MB 物理内存。
		*to_dir = ((unsigned long) to_page_table) | 7;
		nr = (from==0)?0xA0:1024;
// 此时对于当前页表，开始循环复制指定的 nr 个内存页面表项。先取出源页表项内容，如果 
// 当前源页面没有使用（项内容为 0），则不用复制该表项，继续处理下一项。
		for ( ; nr-- > 0 ; from_page_table++,to_page_table++) {
			this_page = *from_page_table;
			if (!this_page)
				continue;
// 如果该表项有内容，但是其存在位 P=0，则该表项对应的页面可能在交换设备中。于是先申 
// 请 1 页内存，并从交换设备中读入该页面（若交换设备中有的话）。然后将该页表项复制到 
// 目的页表项中。并修改源页表项内容指向该新申请的内存页，并设置表项标志为“页面脏” 
// 加上 7。然后继续处理下一页表项。否则复位页表项中 R/W 标志（位 1 置 0），即让页表项 
// 对应的内存页面只读，然后将该页表项复制到目的页表中。
			if (!(1 & this_page)) {
				if (!(new_page = get_free_page()))
					return -1;
				// >>1表示去掉存在位，获取实际的交换设备索引
				read_swap_page(this_page>>1, (char *) new_page);
				*to_page_table = this_page;			// 将源页表项内容复制到目标页表项之中
				*from_page_table = new_page | (PAGE_DIRTY | 7);	// 更新原页表项
																// 使其指向新申请的内存页
																// 并设置页表项标志为“页面脏”和权限位
				continue;
			}
			this_page &= ~2;						// 将页表设置为只读
			*to_page_table = this_page;				// 将处理过的值写到目标页表项
// 如果该页表项所指物理页面的地址在 1MB 以上，则需要设置内存页面映射数组 mem_map[]。 
// 于是计算页面号，并以它为索引在页面映射数组相应项中增加引用次数。而对于位于 1MB 
// 以下的页面，说明是内核页面，因此不需要对 mem_map[]进行设置。因为 mem_map[]仅用 
// 于管理主内存区中的页面使用情况。 
//
// 因此对于内核移动到任务 0 中并且调用 fork()创建任务 1 时（用于运行 init()），由于此
// 时复制的页面还仍然都在内核代码区域，因此以下判断中的语句不会执行，任务 0 的页面仍然
// 可以随时读写。
// 只有当调用 fork() 的父进程代码处于主内存区（页面位置大于 1MB）时才会执行。这种情况需要
// 在进程调用 execve()，并装载执行了新程序代码时才会出现。 
//
// 258 行语句含义是令源页表项所指内存页也为只读，因为现在开始已有两个进程共用内存 
// 区了。若其中 1 个进程需要进行写操作，则可以通过页异常写保护处理为执行写操作的进 
// 程分配 1 页新空闲页面，也即进行写时复制（copy on write）操作。
			if (this_page > LOW_MEM) {
				*from_page_table = this_page;		// 令源页表项也只读
				this_page -= LOW_MEM;
				this_page >>= 12;
				mem_map[this_page]++;
			}
		}
	}
	invalidate();									// 刷新页变换高速缓冲
	return 0;
}

/*
 * This function puts a page in memory at the wanted address.
 * It returns the physical address of the page gotten, 0 if
 * out of memory (either when trying to access page-table or
 * page.)
 */
// 把一物理内存页面映射到线性地址空间指定位置处。 
// 或者说是把线性地址空间中指定地址 address 处的页面映射到主内存区页面 page 上。实现该功 
// 能的主要工作是在相关页目录项和页表项中设置指定页面的信息。在处理缺页异常的 C 函数
// do_no_page() 中会调用此函数。对于缺页引起的异常，由于任何缺页缘故而对页表作修改时， 
// 并不需要刷新 CPU 的页变换缓冲（或称 Translation Lookaside Buffer - TLB），即使页表项 
// 中标志 P 被从 0 修改成 1。因为无效页项不会被缓冲，因此当修改了一个无效的页表项时不需要 
// 刷新。在此就表现为不用调用 Invalidate()函数。 
//
// 参数 page 是分配的主内存区中某一页面（页帧，页框）的指针；address 是线性地址。
static unsigned long put_page(unsigned long page,unsigned long address)
{
	unsigned long tmp, *page_table;

/* NOTE !!! This uses the fact that _pg_dir=0 */

	if (page < LOW_MEM || page >= HIGH_MEMORY)
		printk("Trying to put page %p at %p\n",page,address);
	if (mem_map[(page-LOW_MEM)>>12] != 1)
		printk("mem_map disagrees with %p at %p\n",page,address);
	page_table = (unsigned long *) ((address>>20) & 0xffc);			// 0xffc只有高10位为1，
																	// 所以这里的意思就是取高10位
																	// 同时让低2位为0，也就是页目录项一项的长度（4字节）
	if ((*page_table)&1)	// 如果页目录项有效(低位P标志为1)，则获取页表地址
		page_table = (unsigned long *) (0xfffff000 & *page_table);
	else {	// 否则说明没有对应的页表，需要分配一个新的页表，并在页目录之中设置相应的条目
		if (!(tmp=get_free_page()))
			return 0;
		*page_table = tmp | 7;
		page_table = (unsigned long *) tmp;
	}
	page_table[(address>>12) & 0x3ff] = page | 7;
/* no need for invalidate */
	return page;
}

/*
 * The previous function doesn't work very well if you also want to mark
 * the page dirty: exec.c wants this, as it has earlier changed the page,
 * and we want the dirty-status to be correct (for VM). Thus the same
 * routine, but this time we mark it dirty too.
 */
// 把一内容已修改过的物理内存页面映射到线性地址空间指定位置处。 
// 该函数与上一个函数 put_page()几乎完全一样，除了本函数在设置页表项内容时， 
// 同时还设置了页面已修改标志（位 6，PAGE_DIRTY）。
unsigned long put_dirty_page(unsigned long page, unsigned long address)
{
	unsigned long tmp, *page_table;

/* NOTE !!! This uses the fact that _pg_dir=0 */

	if (page < LOW_MEM || page >= HIGH_MEMORY)
		printk("Trying to put page %p at %p\n",page,address);
	if (mem_map[(page-LOW_MEM)>>12] != 1)
		printk("mem_map disagrees with %p at %p\n",page,address);
	page_table = (unsigned long *) ((address>>20) & 0xffc);
	if ((*page_table)&1)
		page_table = (unsigned long *) (0xfffff000 & *page_table);
	else {
		if (!(tmp=get_free_page()))
			return 0;
		*page_table = tmp|7;
		page_table = (unsigned long *) tmp;
	}
	page_table[(address>>12) & 0x3ff] = page | (PAGE_DIRTY | 7);
/* no need for invalidate */
	return page;
}

// 取消写保护页面函数。用于页异常中断过程中写保护异常的处理（写时复制）。
// 在内核创建进程时，新进程与父进程被设置成共享代码和数据内存页面，并且所有这些页面
// 均被设置成只读页面。而当新进程或原进程需要向内存页面写数据时，CPU 就会检测到这个
// 情况并产生页面写保护异常。于是在这个函数中内核就会首先判断要写的页面是否被共享。
// 若没有则把页面设置成可写然后退出；若页面是处于共享状态，则需要重新申请一新页面并
// 复制被写页面内容，以供写进程单独使用。共享因此被取消。
// 这里共享状态指的是mem_map[]位图之中的页引用计数是否大于1
//
// 输入参数为页表项指针。[un_wp_page -- Un-Write Protect-Page]
void un_wp_page(unsigned long * table_entry)
{
	unsigned long old_page,new_page;

// 首先取参数指定的页表项中物理页面位置（地址）并判断该页面是否是共享页面。如果原 
// 页面地址大于内存低端 LOW_MEM（表示在主内存区中），并且其在页面映射字节图数组中 
// 值为 1（表示页面仅被引用 1 次，页面没有被共享），则在该页面的页表项中置 R/W 标志 
// （可写），并刷新页变换高速缓冲，然后返回。即如果该内存页面此时只被一个进程使用， 
// 并且不是内核中的进程，就直接把属性改为可写即可，不用再重新申请一个新页面。
	old_page = 0xfffff000 & *table_entry;		// 取指定页表项中物理页面地址
	if (old_page >= LOW_MEM && mem_map[MAP_NR(old_page)]==1) {
		*table_entry |= 2;
		invalidate();
		return;
	}
// 否则就需要在主内存区内申请一空闲页面给执行写操作的进程单独使用，取消页面共享。
// 如果原页面大于内存低端（则意味着 mem_map[] > 1，页面是共享的），则将原页面的页 
// 面映射字节数组值递减 1。然后将指定页表项内容更新为新页面地址，并置可读写等标志 
// （U/S、R/W、P）。在刷新页变换高速缓冲之后，最后将原页面内容复制到新页面。
	if (!(new_page=get_free_page()))
		oom();							// Out of Memory。内存不足处理
	if (old_page >= LOW_MEM)
		mem_map[MAP_NR(old_page)]--;
	copy_page(old_page,new_page);
	*table_entry = new_page | 7;
	invalidate();
}	

/*
 * This routine handles present pages, when users try to write
 * to a shared page. It is done by copying the page to a new address
 * and decrementing the shared-page counter for the old page.
 *
 * If it's in code space we exit with a segment error.
 */
// 执行共享页面的写保护页面处理。 
// 这是页异常中断处理过程中调用的 C 函数，会在 page.s 程序中被调用。 
// 函数参数 error_code 和 address 是进程在写写保护页面时由 CPU 产生异常而自动生成的。 
// error_code 指出出错类型；address 是产生异常的页面线性地址。
// 在写共享页面时需复制页面（写时复制）。
void do_wp_page(unsigned long error_code,unsigned long address)
{
// 首先判断 CPU 控制寄存器 CR2 给出的引起页面异常的线性地址在什么范围中。如果 address 
// 小于 TASK_SIZE（0x4000000，即 64MB），表示异常页面位置在内核或任务 0 和任务 1 所处 
// 的线性地址范围内，于是发出警告信息“内核范围内存被写保护”；如果 (address–当前 
// 进程代码起始地址)大于一个进程的长度（64MB），表示 address 所指的线性地址不在引起 
// 异常的进程线性地址空间范围内，则在发出出错信息后退出。
	if (address < TASK_SIZE)
		printk("\n\rBAD! KERNEL MEMORY WP-ERR!\n\r");
	if (address - current->start_code > TASK_SIZE) {
		printk("Bad things happen: page error in do_wp_page\n\r");
		do_exit(SIGSEGV);
	}
#if 0
/* we cannot do this yet: the estdio library writes to code space */
/* stupid, stupid. I really want the libc.a from GNU */
	if (CODE_SPACE(address))
		do_exit(SIGSEGV);
#endif

	// 由页表项在页表之中的偏移地址，加上目录表项内容之中对应页表的地址即可得到
	// 页表项的指正，然后再调用un_wp_page对共享的页面进行复制操作
	un_wp_page((unsigned long *)
		(((address>>10) & 0xffc) + (0xfffff000 &
		*((unsigned long *) ((address>>20) &0xffc)))));

}

// 写页面验证。 
// 若页面不可写，则复制页面。在 fork.c 中被内存验证通用函数 verify_area()调用。 
// 参数 address 是指定页面在 4G 空间中的线性地址。
void write_verify(unsigned long address)
{
	unsigned long page;

// 首先取指定线性地址对应的页目录项，并根据目录项中的存在位（P）判断目录项对应的页表是 
// 否存在（存在位 P=1?）。若不存在（P=0）则返回。这样处理是因为对于不存在的页面没有共享 
// 和写时复制可言，并且若程序对此不存在的页面执行写操作时，系统就会因为缺页异常而去执行 
// do_no_page()，并为这个地方使用 put_page()函数映射一个物理页面。接着程序从目录项中取 
// 页表地址，加上指定页面在页表中的页表项偏移值，得对应地址的页表项指针。在该表项中包含 
// 着给定线性地址对应的物理页面。
	if (!( (page = *((unsigned long *) ((address>>20) & 0xffc)) )&1))
		return;
	page &= 0xfffff000;		// 取页表的物理基地址
	page += ((address>>10) & 0xffc);	// 计算页表项指针 
	if ((3 & *(unsigned long *) page) == 1)  /* non-writeable, present */
		un_wp_page((unsigned long *) page);
	return;
}

// 取得一页空闲内存页并映射到指定线性地址处。 
// get_free_page()仅是申请取得了主内存区的一页物理内存。而本函数则不仅是获取到一页 
// 物理内存页面，还进一步调用 put_page()，将物理页面映射到指定的线性地址处。 
// 参数 address 是指定页面的线性地址。
void get_empty_page(unsigned long address)
{
	unsigned long tmp;

	if (!(tmp=get_free_page()) || !put_page(tmp,address)) {
		free_page(tmp);		/* 0 is ok - ignored */
								// free_page()函数的参数 tmp 是 0 也没有关系(也就是说申请空闲页失败了)，
								// 该函数会忽略它并能正常返回。
		oom();
	}
}

/*
 * try_to_share() checks the page at address "address" in the task "p",
 * to see if it exists, and if it is clean. If so, share it with the current
 * task.
 *
 * NOTE! This assumes we have checked that p != current, and that they
 * share the same executable or library.
 */
// 尝试对当前进程指定逻辑地址处的页面进行共享处理。
// 当前进程与进程 p 是同一执行代码，也可以认为当前进程是由 p 进程执行 fork 操作产生的进程，
// 因此它们的代码内容一样。如果未对数据段内容作过修改那么数据段内容也应一样。
// 参数 address 是进程中的逻辑地址，即是当前进程欲与 p 进程共享页面的逻辑页面地址。进程
// p 是将被共享页面的进程。如果 p 进程 address 处的页面存在并且没有被修改过的话，就让当前
// 进程与 p 进程共享之。同时还需要验证指定的地址处是否已经申请了页面，若是则出错，死机。
// 返回：1 - 页面共享处理成功；0 - 失败。
static int try_to_share(unsigned long address, struct task_struct * p)
{
	unsigned long from;
	unsigned long to;
	unsigned long from_page;
	unsigned long to_page;
	unsigned long phys_addr;

// 首先分别求得指定进程 p 中和当前进程中逻辑地址 address 对应的页目录项。为了计算方便我们 
// 先求出给定逻辑地址 address 处的'逻辑'页目录项偏移位置，即以进程空间（0 - 64MB）算出的 
// 页目录项偏移值。该'逻辑'页目录项号加上进程 p 在 CPU 线性空间中起始地址对应的页目录项， 
// 即得到进程 p 中地址 address 处页面所对应的 4G 线性空间中的实际页目录项地址 from_page。 
// 而'逻辑'页目录项偏移加上当前进程起始地址对应的页目录项位置，即可最后得到当前进程中地 
// 址 address 处页面所对应的 4G 线性空间中的实际页目录项地址 to_page。
	from_page = to_page = ((address>>20) & 0xffc);	// 逻辑的目录项偏移
	from_page += ((p->start_code>>20) & 0xffc);		// p进程目录项地址
	to_page += ((current->start_code>>20) & 0xffc);	// 当前进程目录地址

// 在得到这两个进程的的目录项后，下面分别对进程 p 和当前进程进行处理。首先对 p 进程的页表 
// 项进行操作，目标是取得 p 进程中 address 对应的物理内存页面地址，并且判断该物理页面是否 
// 存在，而且干净（没有被修改过，不脏）。方法是先取目录项内容，然后取该目录项对应页表物
// 理地址 from，从而可计算出逻辑地址 address 对应的页表项指针，并取出该页表项内容临时保存 
// 在 phys_addr 中。
    /* is there a page-directory at from? */ /* 在 from处是否存在页目录项？*/
    from = *(unsigned long *) from_page;			// p进程目录项内容
	if (!(from & 1))								// 页表不存在，直接返回
		return 0;
	from &= 0xfffff000;								// 页表地址
	from_page = from + ((address>>10) & 0xffc);		// 页表项指针
	phys_addr = *(unsigned long *) from_page;		// 页表项内容
// 接着看看页表项映射的物理页面是否存在并且干净。0x41 对应页表项中的 D（Dirty）和
// P（Present）标志。如果页面不干净或无效则返回。然后我们从该表项中取出物理页面地址
// 再保存在 phys_addr 中。最后我们再检查一下这个物理页面地址的有效性，即它不应该超过
// 机器最大物理地址值，也不应该小于内存低端(1MB)。
/* is the page clean and present? */
	if ((phys_addr & 0x41) != 0x01)
		return 0;
	phys_addr &= 0xfffff000;
	if (phys_addr >= HIGH_MEMORY || phys_addr < LOW_MEM)
		return 0;
// 类似地，下面对当前进程的表项进行操作。目标是取得当前进程中 address 对应的页表项地址， 
// 并且需确定该页表项还没有映射物理页面，即其 P=0。首先取当前进程页目录项内容 -> to。如果 
// 该目录项无效（P=0），即目录项对应的页表不存在，则申请一空闲页面来存放页表，并更新目 
// 录项 to_page 内容，让其指向该内存页面。
	to = *(unsigned long *) to_page;
	if (!(to & 1))
		if (to = get_free_page())
			*(unsigned long *) to_page = to | 7;
		else
			oom();
// 接着我们取目录项中的页表地址 -> to，加上页表项索引值<<2，即页表项在表中偏移地址，得到 
// 页表项地址 -> to_page。针对该页表项，如果此时我们检查出其对应的物理页面已经存在（P=1）， 
// 则说明原本我们想从 p 进程共享的物理页面现在我们自己已经有了，内核出错。
	to &= 0xfffff000;								// 页表地址
	to_page = to + ((address>>10) & 0xffc);			// 页表项地址
	if (1 & *(unsigned long *) to_page)
		panic("try_to_share: to_page already exists");
// 在找到了进程 p 中逻辑地址 address 处对应的干净并且存在的物理页面，而且也确定了当前进程 
// 中逻辑地址 address 所对应的二级页表项地址之后，我们现在对他们进行共享处理。使用的方法 
// 很简单，那就是首先对 p 进程的页表项进行修改，设置其写保护（R/W= 0，只读）标志。然后让 
// 当前进程复制 p 进程的这个页表项。 此时当前进程逻辑地址 address 处页面即被映射到 p 进程 
// 逻辑地址 address 处页面映射的物理页面上。
/* share them: write-protect */
	*(unsigned long *) from_page &= ~2;
	*(unsigned long *) to_page = *(unsigned long *) from_page;
// 随后刷新页变换高速缓冲，计算所操作物理页面的页面号，并将对应页面映射字节数组项中的引
// 用递增 1。最后返回 1，表示共享处理成功。
	invalidate();
	phys_addr -= LOW_MEM;
	phys_addr >>= 12;
	mem_map[phys_addr]++;
	return 1;
}

/*
 * share_page() tries to find a process that could share a page with
 * the current one. Address is the address of the wanted page relative
 * to the current data space.
 *
 * We first check if it is at all feasible by checking executable->i_count.
 * It should be >1 if there are other tasks sharing this inode.
 */
/* 
 * share_page()试图找到一个进程，它可以与当前进程共享页面。参数 address 是 
 * 当前进程数据空间中期望共享的某页面地址。 
 * 
 * 首先我们通过检测 executable->i_count 来查证是否可行。如果有其他任务已共享 
 * 该 inode，则它应该大于 1。 
 */
// 寻找运行相同执行文件的进程，并尝试与之共享页面。 
// 在发生缺页异常时，首先看看能否与运行同一个执行文件的其他进程进行页面共享处理。该函数 
// 首先判断系统中是否有另一个进程也在运行当前进程一样的执行文件。若有，则在系统当前所有 
// 任务中寻找这样的任务。若找到了这样的任务就尝试与其共享指定地址处的页面。若系统中没有 
// 其他任务正在运行与当前进程相同的执行文件，那么共享页面操作的前提条件不存在，因此函数 
// 立刻退出。
// 判断系统中是否有另一个进程也在执行同一个执行文件的方法是利用进程任务数据结构中的 
// executable 字段（或 library 字段），该字段指向进程正在执行程序（或使用的库文件） 
// 在内存中的 i 节点。 根据该 i 节点的引用次数字段 i_count 我们可以进行这种判断。若节点的 
// i_count 值大于 1，则表明系统中有两个或以上进程正在运行同一个执行文件。于是我们可以对 
// 任务结构数组中所有任务比较，看是否有相同的 executable 字段（或 library 字段）来最后确 
// 定多个进程运行着相同执行文件的情况。 
// 参数 inode 是欲进行共享页面进程执行文件的内存 i 节点。address 是进程中的逻辑地址，即是 
// 当前进程欲与 p 进程共享页面的逻辑页面地址。返回 1 –共享操作成功，0 - 失败。
static int share_page(struct m_inode * inode, unsigned long address)
{
	struct task_struct ** p;

// 首先检查一下参数指定的内存 i 节点引用计数值。 如果该内存 i 节点的引用计数值等于 1 
// （executable->i_count =1）或者 i 节点指针空，表示当前系统中只有 1 个进程在运行该执 
// 行文件或者提供的 i 节点无效。因此无共享可言，直接退出函数。
	if (inode->i_count < 2 || !inode)
		return 0;
// 否则搜索任务数组中所有任务，寻找与当前进程可共享页面的进程，即运行相同执行文件的另一 
// 个进程，并尝试对指定地址的页面进行共享。若进程逻辑地址 address 小于进程库文件在逻辑地 
// 址空间的起始地址 LIBRARY_OFFSET，则表明共享的页面在进程执行文件对应的逻辑地址空间范围 
// 内。于是检查指定 i 节点是否与进程的执行文件 i 节点（即进程的 executable 相同，若不相同则 
// 继续寻找。若逻辑地址 address 大于等于进程库文件在逻辑地址空间的起始地址 LIBRARY_OFFSET， 
// 则表明想要共享的页面在进程使用的库文件中。于是检查指定节点 inode 是否与进程的库文件 i 
// 节点相同，若不相同则继续寻找。如果找到某个进程 p，其 executable 或 library 字段与指定的 
// 节点 inode 相同，则调用页面共享试探函数 try_to_share()尝试页面共享。若共享操作成功，则 
// 函数返回 1，否则返回 0。
	for (p = &LAST_TASK ; p > &FIRST_TASK ; --p) {
		if (!*p)				// 如果任务项空闲，则继续寻找
			continue;
		if (current == *p)		// 如果就是当前任务，也继续寻找
			continue;
		if (address < LIBRARY_OFFSET) {
			if (inode != (*p)->executable)	// 进程执行文件i节点
				continue;
		} else {
			if (inode != (*p)->library)		// 进程使用库文件i节点
				continue;
		}
		if (try_to_share(address,*p))		// 尝试共享页面
			return 1;
	}
	return 0;
}

// 执行缺页处理。 
// 访问不存在页面的处理函数，页异常中断处理过程中调用此函数。在 page.s 程序中被调用。 
// 函数参数 error_code 和 address 是进程在访问页面时因缺页产生异常而由 CPU 自动生成。 
// error_code 指出出错类型，参见本章开始处的“内存页面出错异常”一节；address 是产生 
// 异常的页面线性地址。 
// 1.该函数首先查看所缺页是否在交换设备中，若是则交换进来。
// 2.否则尝试与已加载的相同文件进行页面共享，或者只是由于进程动态申请内存页面而只需映射一
// 页物理内存页即可。
// 3.若共享操作不成功，那么只能从相应文件中读入所缺的数据页面到指定线性地址处。
void do_no_page(unsigned long error_code,unsigned long address)
{
	int nr[4];
	unsigned long tmp;
	unsigned long page;
	int block,i;
	struct m_inode * inode;

// 首先判断 CPU 控制寄存器 CR2 给出的引起页面异常的线性地址在什么范围中。如果 address 
// 小于 TASK_SIZE（0x4000000，即 64MB），表示异常页面位置在内核或任务 0 和任务 1 所处 
// 的线性地址范围内，于是发出警告信息“内核范围内存被写保护”；如果 (address–当前 
// 进程代码起始地址)大于一个进程的长度（64MB），表示 address 所指的线性地址不在引起 
// 异常的进程线性地址空间范围内，则在发出出错信息后退出。
	if (address < TASK_SIZE)
		printk("\n\rBAD!! KERNEL PAGE MISSING\n\r");
	if (address - current->start_code > TASK_SIZE) {
		printk("Bad things happen: nonexistent page error in do_no_page\n\r");
		do_exit(SIGSEGV);
	}
// 然后根据指定的线性地址 address 求出其对应的二级页表项指针，并根据该页表项内容判断 
// address 处的页面是否在交换设备中。若是则调入页面并退出。方法是首先取指定线性地址 
// address 对应的目录项内容，再取出该目录项中二级页表的地址，加上页表项偏移值即得到线 
// 性地址 address 处页面对应的页面表项指针，从而获得页表项内容。若页表项内容不为 0，但 
// 页表项存在位 P=0，则说明该页表项指定的物理页面应该在交换设备中。于是从交换设备中调 
// 入指定页面后退出函数。
	page = *(unsigned long *) ((address >> 20) & 0xffc);	// 取目录项内容
	if (page & 1) {
		page &= 0xfffff000;									// 二级页表地址
		page += (address >> 10) & 0xffc;					// 页表项内容
		tmp = *(unsigned long *) page;					
		if (tmp && !(1 & tmp)) {
			swap_in((unsigned long *) page);				// 从交换设备读页面
			return;
		}
	}
// 否则，我们取得指定线性地址 address 处的页面地址，并算出该地址在进程空间中相对于 
// 进程基址的偏移长度值 tmp，即对应的逻辑地址。从而可以算出缺页页面在执行文件映像中 
// 或在库文件中的具体起始数据块号。
	address &= 0xfffff000;									// address处缺页页面地址
	tmp = address - current->start_code;					// 缺页页面对应逻辑地址
// 1.如果该逻辑地址 tmp 大于库映像文件在进程逻辑空间中的起始位置，说明缺少的页面在库映像文 
// 件中。于是从当前进程任务数据结构中可以取得库映像文件的 i 节点 library，并计算出该缺页 
// 在库文件中的起始数据块号 block。
// 2.如果该逻辑地址 tmp 小于进程的执行映像文件在逻辑地址空间的末端位置，则说明缺少的页面在
// 进程执行文件映像中，于是可以从当前进程任务数据结构中取得执行文件的 i 节点号 executable，
// 并计算出该缺页在执行文件映像中的起始数据块号 block。 
// 3.若逻辑地址 tmp 既不在执行文件映像的地址范围内，也不在库文件空间范围内，则说明缺页是进 
// 程访问动态申请的内存页面数据所致，因此没有对应 i 节点和数据块号（都置空）。 
// 因为块设备上存放的执行文件映像第 1 块数据是程序头结构，因此在读取该文件时需要跳过第 1 
// 块数据。因为每块数据长度为 BLOCK_SIZE = 1KB，因此一页内存可存放 4 个数据块。进程逻辑 
// 地址 tmp 除以数据块大小再加 1 即可得出缺少的页面在执行映像文件中的起始块号 block。
	if (tmp >= LIBRARY_OFFSET ) {
		inode = current->library;			// 库文件i节点和缺页起始号
		block = 1 + (tmp-LIBRARY_OFFSET) / BLOCK_SIZE;
	} else if (tmp < current->end_data) {
		inode = current->executable;		// 执行文件i节点和缺页起始块号
		block = 1 + tmp / BLOCK_SIZE;
	} else {
		inode = NULL;						// 是动态申请的数据或栈内存页面
		block = 0;
	}
// 若是进程访问其动态申请的页面或为了存放栈信息而引起的缺页异常，则直接申请一页物理内存 
// 页面并映射到线性地址 address 处即可。否则说明所缺页面在进程执行文件或库文件范围内，于 
// 是就尝试共享页面操作，若成功则退出。若不成功就只能申请一页物理内存页面 page，然后从设 
// 备上读取执行文件中的相应页面并放置（映射）到进程页面逻辑地址 tmp 处。
	if (!inode) {							// 是动态申请的数据内存也看
		get_empty_page(address);
		return;
	}
	if (share_page(inode,tmp))		// 尝试逻辑地址tmp处页面的共享
		return;
	if (!(page = get_free_page()))			// 申请一页物理内存
		oom();
/* remember that 1 block is used for header */
// 根据这个块号和执行文件的 i 节点，我们就可以从映射位图中找到对应块设备中对应的设备 
// 逻辑块号（保存在 nr[]数组中）。利用 bread_page()即可把这 4 个逻辑块读入到物理页面 
// page 中。
	for (i=0 ; i<4 ; block++,i++)
		nr[i] = bmap(inode,block);
	bread_page(page,inode->i_dev,nr);
// 在读设备逻辑块操作时，可能会出现这样一种情况，即在执行文件中的读取页面位置可能离 
// 文件尾不到 1 个页面的长度。因此就可能读入一些无用的信息。下面的操作就是把这部分超 
// 出执行文件 end_data 以后的部分进行清零处理。当然，若该页面离末端超过 1 页，说明不
// 是从执行文件映像中读取的页面，而是从库文件中读取的，因此不用执行清零操作。
	i = tmp + 4096 - current->end_data;		// 超出的字节长度值
	if (i>4095)								// 离末端超过1页则不用清零
		i = 0;
	tmp = page + 4096;						// tmp 指向页面末端
	while (i-- > 0) {						// 页面末端i字节清零
		tmp--;
		*(char *)tmp = 0;
	}
// 最后把引起缺页异常的一页物理页面映射到指定线性地址 address 处。若操作成功就返回， 
// 否则就释放内存页，显示内存不够。
	if (put_page(page,address))
		return;
	free_page(page);
	oom();
}

// 内存管理初始化。 
// 该函数对 1MB 以上的物理内存区域进行初始化设置工作。内核以页面为单位管理和访问内存，一 
// 个内存页面长度为 4KB。 该函数把 1MB 以上的所有内存划分成一个个页面，并使用一个页面映射 
// 字节数组 mem_map[] 来管理所有这些页面。 对于具有 16MB 内存的机器，该数组共有 3840 项 
// ((16MB - 1MB)/4KB)，即可管理 3840 个物理页面。每当一个内存页面被占用就把 mem_map[] 中
// 对应的的字节项增 1；若释放一个页面，就把对应字节值减 1。若字节项为0，则表示对应页面空 
// 闲；若字节值大于或等于 1，则表示页面被占用或被多个进程共享占用。 
// 由于内核高速缓冲区和部分设备需要使用一定量的内存，因此系统实际可供分配使用的内存量会
// 少些。我们把能够被实际分配使用的内存区域称为“主内存区”，并且其开始地址位置用变量 start_mem 表示，
// 结束地址用 end_mem 表示。对于具有 16MB 内存的 PC 机系统，start_mem 通常 
// 是 4MB，end_mem 是 16MB。 因此此时主内存区范围是4MB — 16MB，共有 3072 个页面可供分配。 
// 而范围 0 - 1MB 的内存区专供内核使用。 
// 参数 start_mem 是可用作页面分配的主内存区起始地址（已去除虚拟盘 RAMDISK 所占内存空间）。
// end_mem 是实际物理内存最大地址，而从 start_mem 到 end_mem 的地址范围就是主内存区。
void mem_init(long start_mem, long end_mem)
{
	int i;

// 首先将 1MB 到 16MB 范围内所有内存页面对应的内存映射字节数组项置为已占用状态，即各项字 
// 节值全部设置成 USED（100）。PAGING_PAGES 被定义为(PAGING_MEMORY>>12)，即 1MB 以上所有 
// 物理内存分页后的内存页面数(15MB/4KB = 3840)。
	HIGH_MEMORY = end_mem;
	for (i=0 ; i<PAGING_PAGES ; i++)
		mem_map[i] = USED;
	i = MAP_NR(start_mem);				// 主内存区起始位置处的页面号
	end_mem -= start_mem;
	end_mem >>= 12;						// 主内存区中的总页面数
	while (end_mem-->0)
		mem_map[i++]=0;					// 主内存区页面对应字节值清零
}

// 显示系统内存信息。
// 根据内存映射字节数组 mem_map[] 中的信息以及页目录和页表内容统计系统中使用的内存页面 
// 数和主内存区中总物理内存页面数。该函数会在 chr_drv/keyboard.S 程序被调用。即 
// 当按下“Shift + Scroll Lock”组合键时会显示系统内存统计信息。
void show_mem(void)
{
	int i,j,k,free=0,total=0;
	int shared=0;
	unsigned long * pg_tbl;

// 首先根据内存映射字节数组 mem_map[]，统计系统主内存区页面总数 total，以及其中空闲页面 
// 数 free 和被共享的页面数 shared。并显示这些信息。
	printk("Mem-info:\n\r");
	for(i=0 ; i<PAGING_PAGES ; i++) {
		if (mem_map[i] == USED)			// 跳过不能用于分配的内存页面
			continue;
		total++;
		if (!mem_map[i])
			free++;						// 主内存区空闲页面统计
		else
			shared += mem_map[i]-1;		// 共享的页面数（字节值>1）
	}
	printk("%d free pages of %d\n\r",free,total);
	printk("%d pages shared\n\r",shared);

// 接着统计处理器分页管理逻辑页面数。页目录表前 4 项供内核代码使用，不列为统计范围。方法 
// 是从第 5 项开始循环处理所有页目录项。若对应的页表存在，那么先统计页表本身占用的内存页 
// 面，然后对该页表中所有页表项对应物理内存页面情况进行统计。
	k = 0;								
	for(i=4 ; i<1024 ;) {
		if (1&pg_dir[i]) {
			if (pg_dir[i]>HIGH_MEMORY) {
				printk("page directory[%d]: %08X\n\r",
					i,pg_dir[i]);
				continue;
			}
			if (pg_dir[i]>LOW_MEM)
				free++,k++;
			pg_tbl=(unsigned long *) (0xfffff000 & pg_dir[i]);
			for(j=0 ; j<1024 ; j++)
				if ((pg_tbl[j]&1) && pg_tbl[j]>LOW_MEM)
					if (pg_tbl[j]>HIGH_MEMORY)
						printk("page_dir[%d][%d]: %08X\n\r",
							i,j, pg_tbl[j]);
					else
						k++,free++;
		}
		i++;
		if (!(i&15) && k) {
			k++,free++;	/* one page/process for task_struct */
			printk("Process %d: %d pages\n\r",(i>>4)-1,k);
			k = 0;
		}
	}
	printk("Memory found: %d (%d)\n\r",free-shared,total);
}
