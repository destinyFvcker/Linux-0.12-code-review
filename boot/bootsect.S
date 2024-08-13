!
! SYS_SIZE is the number of clicks (16 bytes) to be loaded.
! 0x3000 is 0x30000 bytes = 196kB, more than enough for current
! versions of linux
! 在《Linux内核完全注释》一书之中提到这个单位叫做“节” - paragraph，每节等于16个字节，
! 实际上这里16kB是使用 1Kb = 1000 bytes 来计算的，假如使用 1Kb = 1024 bytes的话，应该是192Kb
! 对于当前内核版本这个空间长度已经足够了。
! 当该值是0x8000时，表示内核最大为512KB，因为内存0x90000处开始存放移动后的bootsect和setup
! 的代码，且现在这部分的代码将会被放在0x0000处，因此该值最大不能超过0x9000(576Kb)
!
! 16倍关系
! 0x10 		= 16
! 0x100 	= 256
! 0x1000 	= 4096 		= 4K
! 0x10000	= 65536 	= 64K
! 0x100000	= 1048576	= 1024K = 1M
!
#include <linux/config.h>
SYSSIZE = DEF_SYSSIZE
!
!	bootsect.s		(C) 1991 Linus Torvalds
!	modified by Drew Eckhardt
!
! bootsect.s is loaded at 0x7c00 by the bios-startup routines, and moves
! iself out of the way to address 0x90000, and jumps there.
!
! It then loads 'setup' directly after itself (0x90200), and the system
! at 0x10000, using BIOS interrupts. 
!
! NOTE! currently system is at most 8*65536 bytes long. This should be no
! problem, even in the future. I want to keep it simple. This 512 kB
! kernel size should be enough, especially as this doesn't contain the
! buffer cache as in minix
!
! The loader has been made as simple as possible, and continuos
! read errors will result in a unbreakable loop. Reboot by hand. It
! loads pretty fast by getting whole sectors at a time whenever possible.

! .global 是一个汇编指令符，用于声明一个或多个符号（标识符）为全局符号，使得它们在
! 连接过程中可以被其他文件引用.
.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

SETUPLEN = 4				! nr of setup-sectors
BOOTSEG  = 0x07c0			! original address of boot-sector
INITSEG  = DEF_INITSEG			! we move boot here - out of the way
SETUPSEG = DEF_SETUPSEG			! setup starts here
SYSSEG   = DEF_SYSSEG			! system loaded at 0x10000 (65536).
ENDSEG   = SYSSEG + SYSSIZE		! where to stop loading

! ROOT_DEV & SWAP_DEV are now written by "build".
ROOT_DEV = 0 				! 根文件系统设备使用与系统引导时同样的设备;
SWAP_DEV = 0				! 交换设备使用与系统引导时同样的设备;

! ****** 程序入口点 *******
entry start
! 关于下面为什么mov要先将立即数移动到ax寄存器之中，然后再将ax寄存器之中的值传递到目标寄存器之中
! 这是因为x86硬件架构之中没有一条可以将内存I/O数据线上的信号传递到段寄存器的电子路径
! 具体可以参考 stackoverflow 博客：
! https://stackoverflow.com/questions/19074666/8086-why-cant-we-move-an-immediate-data-into-segment-register
start:
	mov	ax,#BOOTSEG 		! 将0x07c0这个值加载到ax寄存器中
	mov	ds,ax				! 将ds段寄存器设置为0x07C0
							! ds通常用于指向数据段(data segment)，也就是存储程序数据的内存区域

	mov	ax,#INITSEG			
	mov	es,ax				! 将es段寄存器设置为0x9000
							! es通常用于指向附加段，特别是在字符串操作和数据传送中
							! 这里用于将引导扇区之中的数据移动到内存的其他位置
							!
							! P163
							! 在实模式下，寻址一个内存地址主要是使用段和偏移值，段值被存放在段寄存器之中，并且段的长度被固定为64Kb
							! 段内偏移地址存放在任意一个可用于寻址的寄存器之中，
							! 因此，根据段寄存器和偏移寄存器之中的值，就可以算出实际指向的内存地址
							!
							! 段寄存器之中的地址也不是直接作为内存地址使用的，而是先要左移4位(x16)后加偏移量才能得到实际的物理内存地址

	mov	cx,#256
							! 在x86汇编语言之中，cx寄存器通常用作计数器寄存器，
							! 在许多指令之中被用来指定循环的次数或操作的重复次数
							! 在这里被用来设置移动计数值=256字(512字节)，这个寄存器之中值的单位取决于rep后面的命令操作数据的单位

	sub	si,si
							! si(Source Index): 源索引寄存器，通常用于指向源数据的地址

	sub	di,di
							! di(Destination Index): 目的索引寄存器，通常用于指向目标数据的地址
							!
							! sub指令用于执行减法操作，从第一个操作数之中减去第二个操作数，并将结果存储在第一个操作数之中
							! 在这里自己减自己的效果就是快速清零
							! 还有一个快速清零的方法在下面可以看到：自己异或(xor)自己

	rep
							! rep实际上只是一个前缀指令，它会重复执行紧随其后的操作指令，
							! 并递减cx之中的值，直到0为止

	movw
							! 即movs指令，从内存[si]处移动cx个字到[di]处

	jmpi	go,INITSEG
							! 段间跳转，这里INITSEG(0x9000)指出跳转到的段地址，标号go是段内偏移地址
							! jmpi寄存器在跳转的同时会把cs寄存器(代码段寄存器, Code Segment Register)的值设置为目标段

! =================== bootsect.S 将自己移动到了0x9000处，并跳转到那里继续执行 ======================

go:	mov	ax,cs		
	mov	dx,#0xfef4	! arbitrary value >>512 - disk parm size
							! 在这里dx寄存器的作用是暂时存储栈指针的初始值
							!
							! 关于为什么是这个数值，实际上是因为bootsect.S被拷贝到了0x90000之后，
							! 要给自己留出512个字节的空间，所以setup.S实际上是从0x92000开始的(0x1000 = 256)
							! 然后setup.S在磁盘上大概占用了4个扇区，也就是4 * 0x1000 = 0x4000 = 2Kb
							! 所以这个栈指针起码都要是0x96000开外了，再加上栈本身也要预留空间，所以选在了0x9ff00 - 12
							! 这12个字节是为自建的驱动器参数表预留的内存空间

	mov	ds,ax
	mov	es,ax
							! push ax BUG!!!!!
							! push指令执行时，首先将堆栈指针SP减少(向下移动)以给新的数据留出空间。
							! 对于16位系统，SP减少2

	mov	ss,ax		! put stack at 0x9ff00 - 12.
	mov	sp,dx
/*
 *  在这里主要适配了一个跨磁道读取的问题	
 *
 *	Many BIOS's default disk parameter tables will not 
 *	recognize multi-sector reads beyond the maximum sector number
 *	specified in the default diskette parameter tables - this may
 *	mean 7 sectors in some cases.
 *
 *	Since single sector reads are slow and out of the question,
 *	we must take care of this by creating new parameter tables
 *	(for the first disk) in RAM.  We will set the maximum sector
 *	count to 18 - the most we will encounter on an HD 1.44.  
 *
 *	High doesn't hurt.  Low does.
 *
 *	Segments are as follows: ds=es=ss=cs - INITSEG,
 *		fs = 0, gs = parameter table segment
 */


	push	#0
	pop	fs					! 这个对寄存器清零的方式也是挺别致的
	mov	bx,#0x78			! fs:bx is parameter table address
	seg fs
							! seg fs表示其下一条语句的操作数在fs段中，该指令仅仅影响其下一条语句
	lgs	si,(bx)				! gs:si is source
							! 圆括号在这里的含义似乎是取对应地址上的值，这不是Intel汇编吗?怎么使用的是AT&T语法
							! 所以lgs就是把fs:bi指向的软驱参数表的地址放到gs:si之中

	mov	di,dx				! es:di is destination
							! dx保存有栈指针的内存地址
	mov	cx,#6				! copy 12 bytes
	cld					
							! 清方向标志，复制时指针递增
							!
							! 注意!这里不是在对栈进行操作，而是对后面的自定义参数表进行操作!
							! 所以指针是递增的而不是递减的

	rep
	seg gs
	movw					! movw 指令本来默认使用的寄存器是: ds:si(源地址)和es:di(目的地址)
							! 但是这里通过seg gs更改ds为gs，所以这里源地址为gs:si
							! 因为DF寄存器清零，所以在每次rep之中，si和di寄存器之中的值都会+2(byte)

	mov	di,dx
							! 回退di寄存器的值到复制之前的状态
							! 在这行语句执行完毕之后，es:di就指向新表了，地址从小到大增长
							! 然后我们要做的就是修改表中偏移4处的最大扇区数

	movb	4(di),*18		! patch sector count
							! 这个指令很奇怪，*是立即数的意思吗？我在网络上没有找到其他的解释

	seg fs
	mov	(bx),di
							! 将di寄存器的值复制到fs:bx处
	seg fs
	mov	2(bx),es
							! 将es寄存器的值复制到fs:bx + 2处
							! 效果就是让中断向量0x1E的值指向新表，但是这个内存布局……先是偏移量，再是段基址吗?

	mov ax, cs				! pop ax - fix this bug
	mov	fs,ax
	mov	gs,ax				
							! 至于这里为什么pop出了一个不知道多少的ax值还可以运行正常
							! 当然是因为之后再也没有用过这两个寄存器了(滑稽)
							! 
							! 实际上按照原来的写法的话，似乎发生了栈下溢
							! 栈下溢(Stack Underflow) 如果你在没有正确管理栈的情况下反复调用 POP 指令，
							! 可能会导致栈下溢。这种情况发生在栈已经空了，但你仍然尝试弹出数据。
							! 栈下溢会导致不可预知的行为，因为此时 POP 指令将从栈指针以下的位置读取数据，这可能是无效或未定义的内存区域。
	
	xor	ah,ah			! reset FDC ! 复位磁盘控制器，让其采用新参数
	xor	dl,dl			! dl = 0，也就是第一个软驱
						!
						! xor操作会逐位比较两个二进制数，按照下面的规则机场结果:
						! 如果对应的两位相同，结果为0
						! 如果对应的两位不同，结果为1
	int 	0x13	
						! 这行代码触发BIOS的中断0x13，也就是BIOS提供的硬盘服务中断，
						! 在调用0x13中断时，ah寄存器之中的内容决定了要执行的操作。
						! 此处，ah = 0标志请求复位软盘控制器，dl寄存器表示选择的软驱编号

! ====================== 
! 上面这段代码主要初始化了一些寄存器的值，
! 然后修改了系统的软驱参数表之中关于最大扇区数的字段，使其可以一次性读取更多的数据 
! ======================

! load the setup-sectors directly after the bootblock.
! Note that 'es' is already set up.(0x9000)
! ===========================================
! 在bootsect程序块后紧跟着加载setup模块的代码数据
! 注意在这里es已经设置好了(在进入go过程的开始就将es指向了目的段地址0x9000)
! ===========================================

/*
 * INT 0x13 读扇区使用的调用参数设置如下：
 * ah = 0x02 - 表示操作是读磁盘扇区h到内存;
 * al = 需要读出的扇区数量;
 * ch = 磁道(柱面)号的低8位;					   
 * cl = 开始扇区(位0-5), 磁道号高2位(位6-7);
 * dh = 磁头号;
 * dl = 驱动器号(如果是硬盘则为7要置位)
 * es:bs -> 指向数据缓冲区，如果在读取过程之中出错则CF标志置位，ah之中是出错码
 */

load_setup:
	xor	dx, dx			! drive 0, head 0
	mov	cx,#0x0002		! sector 2, track 0
	mov	bx,#0x0200		! address = 512, in INITSEG
	mov	ax,#0x0200+SETUPLEN	! service 2, nr of sectors
						! 关于这里为什么没有用到ah寄存器等，反而是ax、bx、cx寄存器，
						! 实际上使用ax寄存器允许直接设置ah和al两个部分的值。
						! ax是一个16位寄存器，ah是其高8位，al是低8位(从名字就可以看出来，h=high，l=low)。
						! 其它同理

	int	0x13			! read it
	jnc	ok_load_setup	! ok - continue
						! jnc指令的作用是条件跳转，具体是在无进位(Carry Flag, CF)标志位
						! 没有被置位的时候进行跳转，也就是说，当前一个指令执行后，如果没有发生进位
						! 或借位操作，jnc指令会跳转到指定的目标位置

	push	ax			! dump error code ! 显示出错信息，出错码入栈
	call	print_nl	! 屏幕光标回车
	mov	bp, sp			! ss:bp指向欲显示的字(word)
	call	print_hex	! 显示十六进制值
	pop	ax	
	
	xor	dl, dl			! reset FDC
	xor	ah, ah
	int	0x13
	j	load_setup

ok_load_setup:

! Get disk drive parameters, specifically numbers of sectors/track
! 这段代码利用 BIOS INT 0x13 功能 8 来获取磁盘驱动器的参数。
! 实际上是获取每磁道的扇区数，并将其保存在位置 sectors 处。
! 获取磁盘驱动器参数的 INT 0x13 调用格式和返回信息如下

! ah = 0x08 
! dl = 驱动器号(如果是硬盘，则需要将第 7 位设置为 1)。

! 返回信息：
! 如果出错则 CF 置位，并且 ah = 状态码。 
! bl = 驱动器类型(AT/PS2)
! ch = 最大磁道号的低 8 位， 
! dh = 最大磁头数，
! es:di -> 软驱磁盘参数表。
! cl = 每磁道最大扇区数 (位 0-5)，最大磁道号高 2 位 (位 6-7)
! dl = 驱动器数量，

	xor	dl,dl
	mov	ah,#0x08		! AH=8 is get drive parameters
	int	0x13
	xor	ch,ch
	seg cs
	mov	sectors,cx		! 保存每磁道扇区数。
						! 对于软盘来说(dl=0)，其最大磁道号不会超过256，ch已经足够表示它，
						! 因此cl的位6-7肯定是0.又 xor ch,ch 已经置 ch=0，因此此时cs之中就是每磁道扇区数
	mov	ax,#INITSEG
	mov	es,ax
						! 因为上面取磁盘参数中断更改了es值，这里重新改回为0x9000

! Print some inane message
! 下面利用 BIOS INT 0x10 功能 0x03 和 0x13 来显示信息：“'Loading'+回车+换行”，显示包括 
! 回车和换行控制字符在内共 9 个字符。 
!
! BIOS 中断 0x10 功能号 ah = 0x03，读光标位置。 
! 输入: bh = 页号 
! 返回: ch = 扫描开始线, cl = 扫描结束线, dh = 行号(0x00 顶端) dl = 列号(0x00 最左边)。 
!
! BIOS 中断 0x10 功能号 ah = 0x13，显示字符串。 
! 输入: al = 放置光标的方式及规定属性。0x01-表示使用 bl 中的属性值，光标停在字符串结尾处。 
! bh = 显示页面号, bl = 字符属性, dh = 行号, dl = 列号。cx = 显示的字符串字符数。 
! es:bp 此寄存器对指向要显示的字符串起始位置处。

	mov	ah,#0x03		! read cursor pos
	xor	bh,bh
	int	0x10
	
	mov	cx,#9
	mov	bx,#0x0007		! page 0, attribute 7 (normal)
	mov	bp,#msg1
	mov	ax,#0x1301		! write string, move cursor
	int	0x10

! ok, we've written the message, now
! we want to load the system (at 0x10000)

	mov	ax,#SYSSEG
	mov	es,ax		! segment of 0x010000
	call	read_it		! 读磁盘上的system模块，es为输入参数
	call	kill_motor	! 关闭驱动器马达，这样就可以知道驱动器的状态了
	call	print_nl	! 光标回车换行

! After that we check which root-device to use. If the device is
! defined (!= 0), nothing is done and the given device is used.
! Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
! on the number of sectors that the BIOS reports currently.
! 
! 这里就已经是bootsect.S程序的尾声阶段了，在这里我们需要检查使用哪个根文件系统设备(根设备)
! 在根文件系统设备之中包含了操作系统的核心文件、系统配置文件、用户程序、库文件、以及其他必要的资源，所以这里我们需要先进行确认
! 假如没有指定设备(文件开头定义的ROOT_DEV = 0)，那么就需要根据BIOS报告的每磁道扇区数量来确定到底是使用
! /dev/PS0 (2, 28)，还是/dev/at0 (2, 8)

	seg cs
	mov	ax,root_dev
	or	ax,ax
	jne	root_defined
	seg cs
	mov	bx,sectors
	mov	ax,#0x0208		! /dev/ps0 - 1.2Mb
	cmp	bx,#15
	je	root_defined
	mov	ax,#0x021c		! /dev/PS0 - 1.44Mb
	cmp	bx,#18
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	seg cs
	mov	root_dev,ax		! 这个指令主要对应的是没有设置根文件系统设备的情况

! after that (everyting loaded), we jump to
! the setup-routine loaded directly after
! the bootblock:

	jmpi	0,SETUPSEG

! ===================== bootsect.S 程序结束 ========================

! This routine loads the system at address 0x10000, making sure
! no 64kB boundaries are crossed. We try to load it as fast as
! possible, loading whole tracks whenever we can.
!
! in:	es - starting address segment (normally 0x1000)
!
! 下面的伪操作符 .word 用于定义一个2自己目标，相当于C语言程序之中定义的变量和所占内存空间大小
! sread -> size to read, 现在已经读了1(引导扇区) + SETUPLEN(在文件开头定义的 = 4)
sread:	.word 1+SETUPLEN	! sectors read of current track
head:	.word 0			! current head
						! 磁头号，每个盘片的两个表面都有数据存储区域。每一个表面都有一个独立的磁头用于读写数据
						! 每个磁头都有一个位移的编号，通常从0开始，就像是一个硬盘有两个盘片，
						! 每个盘片有两个表面，那么总共有4个磁头，它们的编号分别为0、1、2和3。

track:	.word 0			! current track
						! 磁道号是磁盘表面上同心圆路径的编号，通常从磁盘的外缘开始，编号从0开始增加

						! 在磁盘上定位数据时，磁头号和磁道号共同指示了磁盘上的一个特定位置。
						! 例如，某一特定位置可能在某个盘片的某一面(由磁头号确定)的某一磁道(由磁道号确定)上

read_it:
	mov ax,es
	test ax,#0x0fff
						! 指令test以比特位逻辑与两个操作数。若两个操作数对应的比特位都为1，则结果 
						! 值的对应比特位为1，否则为0, 假如得到的结果都是0的话，零标志ZF将会置位,
						! 此时jne就不成立

die:	jne die			! es must be at 64kB boundary
	xor bx,bx		! bx is starting address within segment
rp_read:
	mov ax,es			! 此时es的值为0x1000
	cmp ax,#ENDSEG		! have we loaded all yet?
	jb ok1_read
	ret
ok1_read:
	seg cs
	mov ax,sectors		! 取每磁道扇区数
	sub ax,sread		! 减去当前磁道已读扇区数
	mov cx,ax			! = 准备读取的扇区数
	shl cx,#9			! cx = cx * 512, 计算处剩余扇区对应的字节数
	add cx,bx			! cx = cx + bx(段内偏移), 计算当前读取操作后在段内的字节偏移量
						! 这里记录的是此次读操作之后，段内总共读入的字节数

	jnc ok2_read		! 如果没有超过64Kb，则跳转到ok2_read处执行
						! 这里实际上很巧妙

	je ok2_read			! 如果结果正好等于64Kb，就跳转到ok2_read
	xor ax,ax
	sub ax,bx
	shr ax,#9
ok2_read:
	call read_track
	mov cx,ax
	add ax,sread
	seg cs
	cmp ax,sectors
	jne ok3_read
	mov ax,#1
	sub ax,head
	jne ok4_read
	inc track
ok4_read:
	mov head,ax
	xor ax,ax
ok3_read:
	mov sread,ax
	shl cx,#9
	add bx,cx
	jnc rp_read
	mov ax,es
	add ah,#0x10
	mov es,ax
	xor bx,bx
	jmp rp_read

read_track:
	pusha
	pusha	
	mov	ax, #0xe2e 	! loading... message 2e = .
	mov	bx, #7
 	int	0x10
	popa		

	mov dx,track
	mov cx,sread
	inc cx
	mov ch,dl
	mov dx,head
	mov dh,dl
	and dx,#0x0100
	mov ah,#2
	
	push	dx				! save for error dump
	push	cx
	push	bx
	push	ax

	int 0x13
	jc bad_rt
	add	sp, #8   	
	popa
	ret

bad_rt:	push	ax				! save error code
	call	print_all			! ah = error, al = read
	
	
	xor ah,ah
	xor dl,dl
	int 0x13
	

	add	sp, #10
	popa	
	jmp read_track

/*
 *	print_all is for debugging purposes.  
 *	It will print out all of the registers.  The assumption is that this is
 *	called from a routine, with a stack frame like
 *	dx 
 *	cx
 *	bx
 *	ax
 *	error
 *	ret <- sp
 *
*/
 
print_all:
	mov	cx, #5		! error code + 4 registers
	mov	bp, sp	

print_loop:
	push	cx		! save count left
	call	print_nl	! nl for readability
	jae	no_reg		! see if register name is needed
	
	mov	ax, #0xe05 + 0x41 - 1
	sub	al, cl
	int	0x10

	mov	al, #0x58 	! X
	int	0x10

	mov	al, #0x3a 	! :
	int	0x10

no_reg:
	add	bp, #2		! next register
	call	print_hex	! print it
	pop	cx
	loop	print_loop
	ret

print_nl:
	mov	ax, #0xe0d	! CR
	int	0x10
	mov	al, #0xa	! LF
	int 	0x10
	ret

/*
 *	print_hex is for debugging purposes, and prints the word
 *	pointed to by ss:bp in hexadecmial.
*/

print_hex:
	mov	cx, #4		! 4 hex digits
	mov	dx, (bp)	! load word into dx
print_digit:
	rol	dx, #4		! rotate so that lowest 4 bits are used
	mov	ah, #0xe	
	mov	al, dl		! mask off so we have only next nibble
	and	al, #0xf
	add	al, #0x30	! convert to 0 based digit, '0'
	cmp	al, #0x39	! check for overflow
	jbe	good_digit
	add	al, #0x41 - 0x30 - 0xa 	! 'A' - '0' - 0xa

good_digit:
	int	0x10
	loop	print_digit
	ret


/*
 * This procedure turns off the floppy drive motor, so
 * that we enter the kernel in a known state, and
 * don't have to worry about it later.
 */
kill_motor:
	push dx
	mov dx,#0x3f2
	xor al, al
	outb
	pop dx
	ret

sectors:
	.word 0

msg1:
	.byte 13,10
	.ascii "Loading"

.org 506
swap_dev:
	.word SWAP_DEV
root_dev:
	.word ROOT_DEV
boot_flag:
	.word 0xAA55

.text
endtext:
.data
enddata:
.bss
endbss:

