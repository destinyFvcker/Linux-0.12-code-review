/*
 *  linux/boot/head.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 *  head.s contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00000000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory.
 * 注意!!! 32 位启动代码是从绝对地址0x0000_0000开始的，这里也同样是页目录存在的地方，
 * 因此这里的启动代码将会被页目录覆盖掉
 */
.text
.globl _idt,_gdt,_pg_dir,_tmp_floppy_area
_pg_dir:	# 页目录将会存放在这里

# 再次注意!! 这里已经处于 32 位运行模式，因此这里$0x10现在是一个选择符。这里的移动指令 
# 会把相应描述符内容加载进段寄存器中。
#
# 这里$0x10的含义是： 
# 请求特权级为0(位0-1=0)、选择全局描述符表(位2=0)、选择表中第2项(位3-15=2)。它正好 
# 指向表中的数据段描述符项（描述符的具体数值参见前面 setup.s ）。 
#
# 下面代码的含义是：设置 ds,es,fs,gs 为 setup.s 中构造的内核数据段的选择符=0x10
# 并将堆栈放置在 stack_start 指向的 user_stack 数组区，然后使用本程序 
# 后面定义的新中断描述符表（232 行）和全局段描述表（234—238 行）。新全局段描述表中初始 
# 内容与 setup.s 中的基本一样，仅段限长从 8MB 修改成了 16MB。stack_start 定义在 
# kernel/sched.c，82--87 行。它是指向 user_stack 数组末端的一个长指针。第 23 行设置这里 
# 使用的栈，姑且称为系统栈。但在移动到任务 0 执行（init/main.c 中 137 行）以后该栈就被用作 
# 任务 0 和任务 1 共同使用的用户栈了。

startup_32:
	movl $0x10,%eax		# 对于GNU汇编，每一个直接操作数要以$开始，否则表示地址
						# 每一个寄存器都要以%开头，eax表示的是32位的ax寄存器
						# 也就是ax寄存器的扩展版 Extended Accumulator Register
						# 实际上eax寄存器的低16位就是ax寄存器
	mov %ax,%ds
	mov %ax,%es
	mov %ax,%fs
	mov %ax,%gs
						# 设置各段寄存器保存的段选择符都指向表中的第2个段描述符

	lss _stack_start,%esp	# 表示_stack_start -> ss:esp，设置系统堆栈
							# 这里是把_stack_start指针的段选择符和偏移量
							# 分别加载到了ss和esp寄存器之中
	call setup_idt		# 调用设置中断描述符表子程序
	call setup_gdt		# 调用设置全局描述符表子程序
	movl $0x10,%eax		# reload all the segment registers
	mov %ax,%ds		# after changing gdt. CS was already
	mov %ax,%es		# reloaded in 'setup_gdt'
	mov %ax,%fs
	mov %ax,%gs

# 这里唯一没有处理的似乎就是CS代码段寄存器，它仍然保持了在setup.S之中设置的段限长8MB
# 的状态。但是由于在这里只是修改了段限长的相关信息，所以8MB的段限长在内核初始化阶段不会有
# 任何问题。
# 另外，在之后内核执行过程中段间跳转指令会重新加载cs，所以在这里没有加载它并不会导致出错

	lss _stack_start,%esp

# 接下来这一小段用于测试 A20 地址线是否已经开启。采用的方法是向内存地址 0x000000 处写入任意 
# 一个数值，然后看内存地址 0x100000(1M)处是否也是这个数值。如果一直相同的话，就一直 
# 比较下去，电脑就死机了。表示地址 A20 线没有选通，内核不能使用 1MB 以上内存。
# 如果选通了，那么程序至多应该在两个循环之后退出
# 
# 注意这里的指令后缀都是l，代表long，也就是32位操作数的版本，其行为是将指定寄存器的值+1
# 这里0x00_0000没有带'$'，所以表示是一个地址，所以这里movl的作用就是将其写入到这个地址上
# cmpl同理

	xorl %eax,%eax
1:	incl %eax		# check that A20 really IS enabled
	movl %eax,0x000000	# loop forever if it isn't
	cmpl %eax,0x100000
	je 1b
					# 局部符号，b代表before，取上一个
/*
 * NOTE! 486 should set bit 16, to check for write-protect in supervisor
 * mode. Then it would be unnecessary with the "verify_area()"-calls.
 * 486 users probably want to set the NE (#5) bit also, so as to use
 * int 16 for math errors.
 */
/*
 * 注意! 在下面这段程序中，486应该将位16置位，以检查在超级用户模式下的写保护，
 * 此后"verify_area()"调用就不需要了。486的用户通常也会想将NE(#5)置位，
 * 以便对数学协处理器的出错使用int 16。
 */
# 上面原注释中提到的 486 CPU 中 CR0 控制寄存器的位 16 是写保护标志 WP（Write-Protect）， 
# 用于禁止超级用户级的程序向一般用户只读页面中进行写操作。该标志主要用于操作系统在创建 
# 新进程时实现写时复制（copy-on-write）方法。 
# 下面这段程序用于检查数学协处理器芯片是否存在。方法是修改控制寄存器 CR0，在 
# 假设存在协处理器的情况下执行一个协处理器指令，如果出错的话则说明协处理器芯片不存在， 
# 需要设置 CR0 中的协处理器仿真位 EM（位 2），并复位协处理器存在标志 MP（位 1）。

	movl %cr0,%eax		# check math chip
	andl $0x80000011,%eax	# Save PG,PE,ET
/* "orl $0x10020,%eax" here for 486 might be good */
	orl $2,%eax		# set MP
	movl %eax,%cr0
	call check_x87
	jmp after_page_tables

/*
 * We depend on ET to be correct. This checks for 287/387.
 */
# 下面 fninit 和 fstsw 是数学协处理器（80287/80387）的指令。
# finit 向协处理器发出初始化命令，它会把协处理器置于一个未受以前操作影响的已知状态，设置 
# 其控制字为默认值、清除状态字和所有浮点栈式寄存器。
# 非等待形式的这条指令（fninit）还会让协处理器终止执行当前正在执行的任何先前的算术操作。
# fstsw 指令取协处理器的状态字。如果系统中存在协处理器的话，那么在执行了 fninit 指令
# 后其状态字低字节肯定为 0。

check_x87:
	fninit
	fstsw %ax
	cmpb $0,%al
	je 1f			/* no coprocessor: have to set bits */
	movl %cr0,%eax
	xorl $6,%eax		/* reset MP, set EM */
	movl %eax,%cr0
	ret
.align 2
1:	.byte 0xDB,0xE4		/* fsetpm for 287, ignored by 387 */
	ret

/*
 *  setup_idt
 *
 *  sets up a idt with 256 entries pointing to
 *  ignore_int, interrupt gates. It then loads
 *  idt. Everything that wants to install itself
 *  in the idt-table may do so themselves. Interrupts
 *  are enabled elsewhere, when we can be relatively
 *  sure everything is ok. This routine will be over-
 *  written by the page tables.
 */
/*
 * 下面这段是设置中断描述符表子程序 setup_idt
 *
 * 将中断描述符表idt设置成具有256个项，并都指向innore_int中断门
 * 然后加载中断描述符表寄存器(通过lidt指令)。真正使用的中断门以后再安装，
 * 当我们在其他地方认为一切都正常时再开启中断
 */
# 中断描述符表中的项虽然也是 8 字节组成，但其格式与全局表中的不同，被称为门描述符 
# (Gate Descriptor)。它的 0-1,6-7 字节是偏移量，2-3 字节是选择符，4-5 字节是一些标志。 
# 这段代码首先在 edx、eax 中组合设置出 8 字节默认的中断描述符值，然后在 idt 表每一项中 
# 都放置该描述符，共 256 项。eax 含有描述符低 4 字节，edx 含有高 4 字节。内核在随后的初始 
# 化过程中会替换安装那些真正实用的中断描述符项。
setup_idt:
	lea ignore_int,%edx		# lea指令的全称是"Load Effective Address",
							# 其功能是将内存地址计算出来并加载到指定寄存器之中，
							# 而不是加载该内存地址处的内容
							# 
							# 这里就是将ingore_int的有效地址(偏移值)放到了edx寄存器之中
	movl $0x00080000,%eax
	movw %dx,%ax		/* selector = 0x0008 = cs */ 
						# 将中断门的段选择子设置为0x0008，也就是代码段
						# 这里就合成出了段选择符和偏移量的一部分
	movw $0x8E00,%dx	/* interrupt gate - dpl=0, present */
						# 4-5字节的一部分标志

	lea _idt,%edi		# _idt是中断描述符表的地址
	mov $256,%ecx
rp_sidt:
	movl %eax,(%edi)	# 将哑中断门描述符存入表中
	movl %edx,4(%edi)	# eax内容放到edi+4所指内存位置处
	addl $8,%edi		# edi指向表中下一项
	dec %ecx
	jne rp_sidt
	lidt idt_descr		# 加载中断描述符表寄存器值
	ret

/*
 *  setup_gdt
 *
 *  This routines sets up a new gdt and loads it.
 *  Only two entries are currently built, the same
 *  ones that were built in init.s. The routine
 *  is VERY complicated at two whole lines, so this
 *  rather long comment is certainly needed :-).
 *  This routine will beoverwritten by the page tables.
 */
/*
 *	设置全局描述符表项setup_gdt
 *	这个子程序设置一个全新的全局描述符表gdt，并加载。此时仅仅创建了
 *	两个表项，与前面的一样。该子程序只有两行，“非常的”复杂，所以当然
 * 	需要这么长的注释了 :-)。
 * 	该子程序将被页表覆盖掉。
 */ 
setup_gdt:
	lgdt gdt_descr
	ret

/*
 * I put the kernel page tables right after the page directory,
 * using 4 of them to span 16 Mb of physical memory. People with
 * more than 16MB will have to expand this.
 */
/*
 * Linux将内核的内存页表直接放在页目录之后，使用了4个表来寻址16MB的物理内存。
 * 如果你有多于16Mb的内存，就需要在这里进行扩充修改
 */
# 每个页表长为 4KB（1 页内存页面），而每个页表项需要 4 个字节，因此一个页表共可以存放 
# 1024 个表项。如果一个页表项寻址 4KB 的地址空间，则一个页表就可以寻址 4 MB 的物理内存。 
# 页表项的格式为：项的前 0-11 位存放一些标志，例如是否在内存中(P 位 0)、读写许可(R/W 位 1)、 
# 普通用户还是超级用户使用(U/S 位 2)、是否修改过(是否脏了)(D 位 6)等；表项的位 12-31 是 
# 页框地址，用于指出一页内存的物理起始地址。
#
# .org伪指令的作用是告诉汇编器从指定的内存地址开始放置接下来的代码或数据
.org 0x1000		# 从偏移 0x1000 处开始是第 1 个页表（偏移 0 开始处将存放页表目录）。
pg0:

.org 0x2000
pg1:

.org 0x3000
pg2:

.org 0x4000
pg3:

.org 0x5000		# 定义下面的内存数据块从偏移0x5000处开始
/*
 * tmp_floppy_area is used by the floppy-driver when DMA cannot
 * reach to a buffer-block. It needs to be aligned, so that it isn't
 * on a 64kB border.
 */
/* 
 * 当 DMA（直接存储器访问）不能访问缓冲块时，下面的 tmp_floppy_area 内存块
 * 就可供软盘驱动程序使用。其地址需要对齐调整，这样就不会跨越 64KB 边界。
 */
_tmp_floppy_area:
	.fill 1024,1,0	# .fill count, size, value
					# count: 表示要重复填充的次数
					# size: 表示每个数据项的大小，通常以字节为单位
					# value: 表示要填充的数据值

# 下面这几个入栈操作用于为跳转到 init/main.c 中的 main()函数作准备工作。
# 前面 3 个入栈 0 值分别表示 main 函数的参数 envp、argv 指针和 argc，但 main()没有用到。 
# 253 行的入栈操作是模拟调用 main 程序时将返回地址入栈的操作，所以如果 main.c 程序 
# 真的退出时，就会返回到这里的标号 L6 处继续执行下去，也即死循环。254 行将 main.c 的地址 
# 压入堆栈，这样，在设置分页处理（setup_paging）结束后执行'ret'返回指令时就会将 main.c 
# 程序的地址弹出堆栈，并去执行 main.c 程序了。
after_page_tables:
	pushl $0		# These are the parameters to main :-)
	pushl $0
	pushl $0
	pushl $L6		# return address for main, if it decides to.
	pushl $_main
	jmp setup_paging
L6:
	jmp L6			# main should never return here, but
				# just in case, we know what happens.

/* This is the default interrupt "handler" :-) */
/* 下面是默认的中断“向量句柄” :-) */
# 也就是说下面这段代码实现了一个默认的中断处理程序，当系统
# 发生未知中断时调用
int_msg:
	.asciz "Unknown interrupt\n\r"
.align 2			# 按4字节方式对齐内存地址
ignore_int:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds		# 这里注意：de,es,fs,gs等虽然是16位的寄存器，但是
	push %es		# 仍然会以32位的形式入栈，也就是需要占用4个字节的堆栈空间
	push %fs		# 这就是上面.align 2的作用
	movl $0x10,%eax	# 置段选择符(使ds,es,fs指向gdt表中的数据段)
	mov %ax,%ds
	mov %ax,%es
	mov %ax,%fs
	pushl $int_msg	# 把调用printk函数的参数指针(地址)入栈。注意！若int_msg
					# 前不加$，则表示把int_msg符号处的长字(就是那堆字符串)入栈
	call _printk	# 该函数在/kernel/printk.c之中，'_printk'是printk编译后
					# 模块之中的内部表示法
	popl %eax	
	pop %fs
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret			# 中断返回（把中断调用时压入栈的CPU标志寄存器32位值也弹出）
					# ret一般用于普通的函数或子程序返回，iret专门用于中断和异常处理的
					# 返回，因为它需要恢复更多的处理器状态以确保系统的稳定性

/*
 * Setup_paging
 *
 * This routine sets up paging by setting the page bit
 * in cr0. The page tables are set up, identity-mapping
 * the first 16MB. The pager assumes that no illegal
 * addresses are produced (ie >4Mb on a 4Mb machine).
 *
 * NOTE! Although all physical memory should be identity
 * mapped by this routine, only the kernel page functions
 * use the >1Mb addresses directly. All "normal" functions
 * use just the lower 1Mb, or the local data space, which
 * will be mapped to some other place - mm keeps track of
 * that.
 *
 * For those with more memory than 16 Mb - tough luck. I've
 * not got it, why should you :-) The source is here. Change
 * it. (Seriously - it shouldn't be too difficult. Mostly
 * change some constants etc. I left it at 16Mb, as my machine
 * even cannot be extended past that (ok, but it was cheap :-)
 * I've tried to show which constants to change by having
 * some kind of marker at them (search for "16Mb"), but I
 * won't guarantee that's all :-( )
 */
/*
 * 这个子程序通过设置控制寄存器 cr0 的标志（PG 位 31）来启动对内存的分页处理功能，
 * 并设置各个页表项的内容，以恒等映射前 16 MB 的物理内存。分页器假定不会产生非法的
 * 地址映射（也即在只有 4Mb 的机器上设置出大于 4Mb 的内存地址）。
 *
 * 注意！尽管所有的物理地址都应该由这个子程序进行恒等映射，但只有内核页面管理函数能
 * 直接使用>1Mb 的地址。所有“普通”函数仅使用低于 1Mb 的地址空间，或者是使用局部数据
 * 空间，该地址空间将被映射到其他一些地方去 -- mm（内存管理程序）会管理这些事的。
 *
 * 对于那些有多于 16Mb 内存的家伙 – 真是太幸运了，我还没有，为什么你会有(哭了)。代码就在 
 * 这里，对它进行修改吧。实际上，这并不是太困难，通常只需修改一些常数等。我把它设置
 * 为 16Mb，因为我的机器再怎么扩充甚至不能超过这个界限（当然，我的机器是很便宜的，哈哈） 
 * 我已经通过设置某类标志来给出需要改动的地方（搜索“16Mb”），但我不能保证作这些 
 * 改动就行了 :-( 。 
 */
# 上面英文注释第 2 段的含义是指在机器物理内存中大于 1MB 的内存空间主要被用于主内存区。 
# 主内存区空间由 mm 模块管理。它涉及到页面映射操作。内核中所有其他函数就是这里指的一般 
#（普通）函数。若要使用主内存区的页面，就需要使用 get_free_page()等函数获取。因为主内 
# 存区中内存页面是共享资源，必须有程序进行统一管理以避免资源争用和竞争。 
# 
# 在内存物理地址 0x0 处开始存放 1 页页目录表和 4 页页表。页目录表是系统所有进程公用的，而 
# 这里的 4 页页表则属于内核专用，它们一一映射线性地址起始 16MB 空间范围到物理内存上。对于 
# 新建的进程，系统会在主内存区为其申请页面存放页表。另外，1 页内存长度是 4096 字节。
.align 2					# 按照4字节对内存进行对齐
setup_paging:				
	movl $1024*5,%ecx		/* 5 pages - pg_dir+4 page tables */
	xorl %eax,%eax
	xorl %edi,%edi			/* pg_dir is at 0x000 */
	cld;rep;stosl			# cld清方向标志(Clear Direction Flag)，确保字符串操作指令
							# 就像是stosl从低地址向高地址方向执行
							#
							# rep指令前缀表示重复执行后面的指令，直到 %ecx 寄存器的值减到 0 为止。
							#
							# tosl 是 store string 指令，作用是将 %eax 中的值（此处为零）存储到由 
							# %edi 指向的内存地址中，然后将 %edi 增加 4（因为 stosl 操作的是 32 位数据）。
							# 每执行一次 stosl，%ecx 减少 1。

# 下面 4 句设置页目录表中的项。因为我们（内核）共有 4 个页表，所以只需设置 4 项。 
# 页目录项的结构与页表中项的结构一样，4 个字节为 1 项。
# 例如"$pg0+7"表示：0x00001007，是页目录表中的第 1 项。 
# 则第 1 个页表所在的地址 = 0x00001007 & 0xfffff000 = 0x1000； 
# 第 1 个页表的属性标志 = 0x00001007 & 0x00000fff = 0x07，表示该页存在、用户可读写。
	movl $pg0+7,_pg_dir		/* set present bit/user r/w */
	movl $pg1+7,_pg_dir+4		/*  --------- " " --------- */
	movl $pg2+7,_pg_dir+8		/*  --------- " " --------- */
	movl $pg3+7,_pg_dir+12		/*  --------- " " --------- */

# 下面 6 行填写 4 个页表中所有项的内容，共有：4(页表)*1024(项/页表)=4096 项(0 - 0xfff)， 
# 也即能映射物理内存 4096*4Kb = 16Mb。 
# 每项的内容是：当前项所映射的物理内存地址 + 该页的标志（这里均为 7）。 
# 填写使用的方法是从最后一个页表的最后一项开始按倒退顺序填写。每一个页表中最后一项在表中 
# 的位置是 1023*4 = 4092。因此最后一页的最后一项的位置就是$pg3+4092。
	movl $pg3+4092,%edi
	movl $0xfff007,%eax		/*  16Mb - 4096 + 7 (r/w user,p) */
	std						# 设置方向标志位(DF)=1，使stosl指令在写入时自动减少EDI的值，
							# 从而使写操作从高地址到低地址进行(倒序填充页表)
1:	stosl			/* fill pages backwards - more efficient :-) */
	subl $0x1000,%eax
	jge 1b					# 如果EAX的值仍然大于或等于0，则跳回标签1，继续向下填充页表。
							# 这种循环填充的方式更为高效。

# 现在设置页目录表基址寄存器 cr3，指向页目录表。cr3 中保存的是页目录表的物理地址，然后 
# 再设置启动使用分页处理（cr0 的 PG 标志，位 31）
	xorl %eax,%eax		/* pg_dir is at 0x0000 */
	movl %eax,%cr3		/* cr3 - page directory start */
	movl %cr0,%eax
	orl $0x80000000,%eax
	movl %eax,%cr0		/* set paging (PG) bit */
	ret			/* this also flushes prefetch-queue */
# 在改变分页处理标志后要求使用转移指令刷新预取指令队列。这里用的是返回指令 ret。 
# 该返回指令的另一个作用是将压入堆栈中的 main 程序的地址弹出，并跳转到/init/main.c 
# 程序去运行。本程序到此就真正结束了。

# 下面是加载中断描述符表寄存器 idtr 的指令 lidt 要求的 6 字节操作数。前 2 字节是 idt 表的限长， 
# 后 4 字节是 idt 表在线性地址空间中的 32 位基地址。
.align 2
.word 0					# 这里现空出2字节，这样下面这个.long长字就是4字节对齐的了
idt_descr:
	.word 256*8-1		# idt contains 256 entries # 共 256 项，限长=长度 - 1。
	.long _idt
.align 2
.word 0

# 下面加载全局描述符表寄存器 gdtr 的指令 lgdt 要求的 6 字节操作数。前 2 字节是 gdt 表的限长， 
# 后 4 字节是 gdt 表的线性基地址。这里全局表长度设置为 2KB 字节（0x7ff 即可），因为每 8 字节 
# 组成一个描述符项，所以表中共可有 256 项。符号_gdt 是全局表在本程序中的偏移位置，见 234 行。
gdt_descr:
	.word 256*8-1		# so does gdt (not that that's any
	.long _gdt		# magic number, but it works for me :^)

	.align 3
_idt:	.fill 256,8,0		# idt is uninitialized

# 全局描述符表。其前 4 项分别是：空项（不用）、代码段描述符、数据段描述符、系统调用段描述符， 
# 其中系统调用段描述符并没有派用处，Linus 当时可能曾想把系统调用代码放在这个独立的段中。 
# 后面还预留了 252 项的空间，用于放置新创建任务的局部描述符(LDT)和对应的任务状态段 TSS 
# 的描述符。 
# (0-nul, 1-cs, 2-ds, 3-syscall, 4-TSS0, 5-LDT0, 6-TSS1, 7-LDT1, 8-TSS2 etc...)
_gdt:	.quad 0x0000000000000000	/* NULL descriptor */
	.quad 0x00c09a0000000fff	/* 16Mb */
	.quad 0x00c0920000000fff	/* 16Mb */
	.quad 0x0000000000000000	/* TEMPORARY - don't use */
	.fill 252,8,0			/* space for LDT's and TSS's etc */
