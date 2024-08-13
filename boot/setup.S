!
!	setup.s		(C) 1991 Linus Torvalds
!
! setup.s is responsible for getting the system data from the BIOS,
! and putting them into the appropriate places in system memory.
! both setup.s and system has been loaded by the bootblock.
!
! This code asks the bios for memory/disk/other parameters, and
! puts them in a "safe" place: 0x90000-0x901FF, ie where the
! boot-block used to be. It is then up to the protected mode
! system to read them from there before the area is overwritten
! for buffer-blocks.
; 猜猜上面说的boot-block是什么模块?实际上就是bootsect.S程序，它在setup.S
; 之中被覆盖了，从地址范围就可以看出来，刚刚好512个字节
;
; 所以系统之中的参数放在这里是相当安全的，这里也揭示了为什么要先将系统加载到0x10000，然后再将其移动到
; 0x0，这是因为还需要利用bios来读取系统配置参数
!

! NOTE! These had better be the same as in bootsect.s!
#include <linux/config.h>

; 在汇编过程之中，汇编器会将这些符号替换为它们对应的值(有点像是宏定义)
INITSEG  = DEF_INITSEG	! we move boot here - out of the way
SYSSEG   = DEF_SYSSEG	! system loaded at 0x10000 (65536).
SETUPSEG = DEF_SETUPSEG	! this is the current segment

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

entry start
start:

; =============== 保存光标位置以备以后使用，顺带设置了显示方式 ================ start

! ok, the read went well so we get current cursor position and save it for
! posterity.

	mov	ax,#INITSEG	! this is done in bootsect already, but...
	mov	ds,ax			; 设置数据段寄存器的值，后面在使用偏移量时会用到

! Get memory size (extended mem, kB)
; 取扩展内存的大小值（KB）。 
; 利用 BIOS 中断 0x15 功能号 ah = 0x88 取系统所含扩展内存大小并保存在内存 0x90002 处。 
; 返回：ax = 从 0x100000（1M）处开始的扩展内存大小(KB)。若出错则 CF 置位，ax = 出错码。
;
; 扩展内存：指的是超过 1MB 的内存区域。在早期的计算机系统中，
; 1MB 以下的内存被称为常规内存，而 1MB 以上的内存称为扩展内存。

	mov	ah,#0x88
	int	0x15
	mov	[2],ax

! check for EGA/VGA and some config parameters 
; 调用BIOS中断0x10功能号0x12(视频子系统配置)取EBA配置信息
; ah = 0x12, bl = 0x10
; 返回:
; bh =显示状态(0x00 -彩色模式，I/O 端口=0x3dX; 0x01 -单色模式，I/O 端口=0x3bX)
; bl = 安装的显示内存(0x00 - 64k; 0x01 - 128k; 0x02 - 192k; 0x03 = 256k) 
; cx = 显示卡特性参数(参见程序后对 BIOS 视频中断 0x10 的说明)

	mov	ah,#0x12
	mov	bl,#0x10
	int	0x10
	mov	[8],ax			! 0x90008 = ??
	mov	[10],bx			! 0x9000A = 安装的显示内存; 0x9000B=显示状态(彩/单色)
	mov	[12],cx			! 0x9000C = 显示卡特性参数

; 检测屏幕当前行列值。若显卡是VGA卡时则请求用户选择显示行列值，并保存到0x9000E处
	mov	ax,#0x5019		; 在ax之中预置屏幕默认行列值(ah = 80列, al = 25行)
	cmp	bl,#0x10		; 假如中断返回bl值为x10，则表示不是VGA显示卡，跳转。
						;
						; 这里一开始就把bl的值置为了0x10，所以如果读取失败的话可能不会修改bl的值
						; 我猜是根据这一点来判断操作是否失败了的
	je	novga		
	call	chsvga		; 检测显示卡厂家和类型，修改显示行列值
novga:	mov	[14],ax		; 保存屏幕当前(实际上就是默认)行列值到0x9000E和0x9000F处

; 使用BOIS中断0x10功能0x03读取屏幕当前光标位置，并保存在内存0x90000处(2字节)
; 控制台初始化程序console.c会到此处读取该值
; 输入: bh = 页号 
; 返回: ch = 扫描开始线; cl = 扫描结束线; dh = 行号(0x00 顶端); dl = 列号(0x00 最左边)。
	mov	ah,#0x03	! read cursor pos
	xor	bh,bh
	int	0x10		! save it in known place, con_init fetches
	mov	[0],dx		! it from 0x90000.
	
! Get video-card data:
	
	mov	ah,#0x0f
	int	0x10
	mov	[4],bx		! bh = display page
	mov	[6],ax		! al = video mode, ah = window width(字符列数)

; ========== end

; =========== 获取硬盘信息(硬盘参数表) ============ start
; 第一个硬盘参数表的首地址是中断0x41中断向量值
; 中断0x46的向量向量值也指向第2个硬盘的参数表首地址
; 表的长度是16字节

; 第一个硬盘是肯定有的
! Get hd0 data

	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x41]
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0080
	mov	cx,#0x10
	rep
	movsb

; 第二个硬盘就不一定有了
! Get hd1 data

	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x46]
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	rep
	movsb

! Check that there IS a hd1 :-)

	mov	ax,#0x01500
	mov	dl,#0x81
	int	0x13
	jc	no_disk1
	cmp	ah,#3
	je	is_disk1
no_disk1:
	; 如果没有第2个硬盘的话，就把第二个表清零
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	mov	ax,#0x00
	rep
	stosb
is_disk1:

; ================= end

; ================= 进入保护模式相关寄存器设置(GDT/IDT) ============= start

! now we want to move to protected mode ...

	cli			! no interrupts allowed !

! first we move the system to it's rightful place
; 之前在bootsect.S之中我们是把system模块加载到了0x10000之中
; 现在要做的就是把从0x10000到0x90000这一块内存(512Kb)向下整体移动0x10000 byte(64Kb)
; 之前bios的中断向量表和一些运行数据都放在这块内存之中
; 但是由于我们在上面读取完了硬件信息(屏幕、硬盘)，现在已经用不到了，所以可以将其覆盖

	mov	ax,#0x0000
	cld			! 'direction'=0, movs moves forward
; 个人感觉下面这段移动数据的小过程十分经典，值的学习
do_move:
	mov	es,ax		! destination segment
	add	ax,#0x1000
	cmp	ax,#0x9000	; 是否已经把最后一段(从0x8000段开始的64Kb)代码移动完
	jz	end_move
	mov	ds,ax		! source segment
	sub	di,di
	sub	si,si
	mov 	cx,#0x8000
	rep
	movsw
	jmp	do_move

! then we load the segment descriptors

end_move:
	mov	ax,#SETUPSEG	! right, forgot this at first. didn't work :-)
	mov	ds,ax

	; 下面这两个指令的操作数在文件末尾部分定义
	lidt	idt_48		! load idt with 0,0
	lgdt	gdt_48		! load gdt with whatever appropriate

! that was painless, now we enable A20
; 为了能够访问和使用 1MB 以上的物理内存，我们需要首先开启 A20 地址线。
; 关于所涉及的一些端口和命令，可参考 kernel/chr_drv/keyboard.S 
; 程序后对键盘接口的说明。至于机器是否真正开启了 A20 地址线，我们还需要在进入保护模式 
; 之后（能访问 1MB 以上内存之后）在测试一下。这个工作放在了 head.S 程序中。

	call	empty_8042	; 测试8042状态寄存器，等待输入缓冲器空
						; 只有当输入缓冲器为空时才能对其执行写命令
	mov	al,#0xD1		! command write
						; 0xD1命令码表示要写数据到8042的P2端口，
						; P2端口位1用于A20线的选通
	out	#0x64,al
						; out指令用于向指定的i/o端口输出一个字节或字(word)的数据
						; 0x60和0x64都是用于与键盘控制器通信的常用I/O端口
	call	empty_8042
	mov	al,#0xDF		! A20 on
						; 选通A20地址线的参数
	out	#0x60,al
						; 数据要写到0x60口
	call	empty_8042
						; 若果此时输入缓冲器位空，则表示A20线已经选通

! well, that went ok, I hope. Now we have to reprogram the interrupts :-(
! we put them right after the intel-reserved hardware interrupts, at
! int 0x20-0x2F. There they won't mess up anything. Sadly IBM really
! messed this up with the original PC, and they haven't been able to
! rectify it afterwards. Thus the bios puts interrupts at 0x08-0x0f,
! which is used for the internal hardware interrupts as well. We just
! have to reprogram the 8259's, and it isn't fun.
; 8295芯片主端口是0x20-0x21，从片端口是0xA0-0xA1
; 输出值0x11表示初始化命令开始，这是ICW1命令字，包含了下面三层含义：
; 1. 边沿触发 2. 多片8259级联 3. 最后发送ICW4命令字
	mov	al,#0x11		! initialization sequence
	out	#0x20,al		! send it to 8259A-1 ; 发送到8259A主芯片
	.word	0x00eb,0x00eb		! jmp $+2, jmp $+2	; '$' 表示当前指令的地址
								; 0xed是“直接近跳转指令”的操作码，带一个字节的相对位偏移.在这里用于提供一点时钟周期的延时作用
								; 所以跳转范围就是-127 - 127.
								;
								; CPU通过把这个相对位移值加载到EIP寄存器之中就形成一个新的有效地址,
								; 执行时所花费的CPU时钟周期数是7至10个.
								;
								; 这里0x00eb表示跳转位移值是0的一条指令，因此还是直接执行下一条指令
								; 这两条指令一共可以提供14--20个CPU时钟周期的延迟时间。
								; 在as86之中并没有提供相关指令的助记符
	out	#0xA0,al		! and to 8259A-2 ; 发送到8259A从芯片
	.word	0x00eb,0x00eb

; 在Linux系统硬件中断号被设置成从0x20开始
	mov	al,#0x20		! start of hardware int's (0x20) 
	out	#0x21,al		; 送主芯片ICW2命令字，设置起始中断号，要送奇端口
	.word	0x00eb,0x00eb	
	mov	al,#0x28		! start of hardware int's 2 (0x28)
	out	#0xA1,al		; 送从芯片ICW2命令字，从芯片的起始中断号
	.word	0x00eb,0x00eb

	mov	al,#0x04		! 8259-1 is master
	out	#0x21,al		; 送主芯片ICW3命令字，主芯片的IR2连从芯片INT
	.word	0x00eb,0x00eb
	mov	al,#0x02		! 8259-2 is slave
	out	#0xA1,al		; 送从芯片ICW3命令字，表示从芯片的INT连主芯片IR2引脚
	.word	0x00eb,0x00eb

	mov	al,#0x01		! 8086 mode for both
	out	#0x21,al		; 送主芯片ICW4命令字：8086模式、普通EOI、非缓冲方式
						; 需发送指令来复位。
	.word	0x00eb,0x00eb
	out	#0xA1,al		; 送从芯片ICW4命令字

; 初始化结束，主从两块8259A芯片已就绪
	.word	0x00eb,0x00eb
	mov	al,#0xFF		! mask off all interrupts for now
	out	#0x21,al		; 屏蔽主芯片所有中断请求
	.word	0x00eb,0x00eb
	out	#0xA1,al		; 屏蔽从芯片所有中断请求

! well, that certainly wasn't fun :-(. Hopefully it works, and we don't
! need no steenking BIOS anyway (except for the initial loading :-).
! The BIOS-routine wants lots of unnecessary data, and it's less
! "interesting" anyway. This is how REAL programmers do it.
!
! Well, now's the time to actually move into protected mode. To make
! things as simple as possible, we do no register set-up or anything,
! we let the gnu-compiled 32-bit programs do that. We just jump to
! absolute address 0x00000, in 32-bit protected mode.
!
; 当然了，上面这段编程十分没劲:-(，但希望这样能工作，而且我们也不再需要乏味的 BIOS 
; 了（除了初始加载:-)。BIOS 子程序要求很多不必要的数据，而且它一点都没趣。那是 
; “真正”的程序员所做的事(硬件科研机油佬)。 
;
; 好了，现在是真正开始进入保护模式的时候了。为了把事情做得尽量简单，我们并不对 
; 寄存器内容进行任何设置。我们让 gnu 编译的 32 位程序去处理这些事。在进入 32 位保 
; 护模式时我们仅是简单地跳转到绝对地址 0x00000 处。
;
; 下面设置并进入 32 位保护模式运行。首先加载机器状态字(lmsw-Load Machine Status Word)， 
; 也称控制寄存器 CR0，其比特位 0 置 1 将导致 CPU 切换到保护模式，并且运行在特权级 0 中，即 
; 当前特权级 CPL=0。此时段寄存器仍然指向与实地址模式中相同的线性地址处（在实地址模式下 
; 线性地址与物理内存地址相同）。
; 在设置该比特位后，随后一条指令必须是一条段间跳转指令以用于刷新 CPU 当前指令队列。
; [注意！！！因为CPU是在执行一条指令之前就已从内存读取该指令并对其进行解码]。然而在进入保护模式以后那些
; 属于实模式的预先取得的指令信息就变得不再有效。而一条段间跳转指令就会刷新 CPU 的当前指令队列，
; 即丢弃这些无效信息。
; 另外，在 Intel 公司的手册上建议 80386 或以上 CPU 应该使用指令“mov cr0,ax”切换到保护模式。
; lmsw 指令仅用于兼容以前的 286 CPU。

	mov	ax,#0x0001	! protected mode (PE) bit
	lmsw	ax		! This is it!
					; LMSW是 Load Machine Status Word的缩写
					; 这条指令将ax之中的值加载到机器状态字的低16位

; [注意！！！现在已经进入到保护模式之中了]
	jmpi	0,8		! jmp offset 0 of segment 8 (cs)
; 我们已经将 system 模块移动到 0x00000 开始的地方，所以上句中的偏移地址是 0。而段值 8 已经 
; 是保护模式下的段选择符了，用于选择描述符表和描述符表项以及所要求的特权级。
;
; 段选择符长度为 16 位（2 字节）:
; - 位 0-1 表示请求的特权级 0--3，但 Linux 操作系统只用到两级：0 级（内核级）和 3 级（用户级）；
; - 位 2 用于选择全局描述符表（0）还是局部描述符表(1)；
; - 位 3-15 是描述符表项的索引；
; 所以段选择符 8（0b0000,0000,0000,1000）表示请求 特权级 0、使用全局描述符表 GDT 中第 
; 2 个段(索引从0开始，这里为1)描述符项，该项指出代码的基地址是 0 
; 因此这里的跳转指令就会去执行 system 中的代码。

! This routine checks that the keyboard command queue is empty
! No timeout is used - if this hangs there is something wrong with
! the machine, and we probably couldn't proceed anyway.
; 下面这个子程序检查键盘命令队列是否为空。这里不使用超时方法 -
; 如果这里死机，则说明 PC 机有问题，我们就没有办法再处理下去了。
;
; 只有当输入缓冲器为空时（键盘控制器状态寄存器位 1 = 0）才可以对其执行写命令。
empty_8042:
	.word	0x00eb,0x00eb
	in	al,#0x64	! 8042 status port
					; in 指令用于从I/O端口0x64读取数据，并将其存入寄存器al
	test	al,#2		! is input buffer full?
						; 2 = 0000_0010
	jnz	empty_8042	! yes - loop
					; jnz指令是“跳转如果不为零”
					; Jump if Not Zero，通过检查标志寄存器的零标志(ZF)
					; 进行条件跳转
	ret

; ============== 配置VGA显卡 ============== start
; 在692行结束

! Routine trying to recognize type of SVGA-board present (if any)
! and if it recognize one gives the choices of resolution it offers.
! If one is found the resolution chosen is given by al,ah (rows,cols).

chsvga:	cld
	push	ds
	push	cs
	pop	ds
	mov 	ax,#0xc000
	mov	es,ax
	lea	si,msg1
	call	prtstr
nokey:	in	al,#0x60
	cmp	al,#0x82
	jb	nokey
	cmp	al,#0xe0
	ja	nokey
	cmp	al,#0x9c
	je	svga
	mov	ax,#0x5019
	pop	ds
	ret
svga:	lea 	si,idati		! Check ATI 'clues'
	mov	di,#0x31
	mov 	cx,#0x09
	repe
	cmpsb
	jne	noati
	lea	si,dscati
	lea	di,moati
	lea	cx,selmod
	jmp	cx
noati:	mov	ax,#0x200f		! Check Ahead 'clues'
	mov	dx,#0x3ce
	out	dx,ax
	inc	dx
	in	al,dx
	cmp	al,#0x20
	je	isahed
	cmp	al,#0x21
	jne	noahed
isahed:	lea	si,dscahead
	lea	di,moahead
	lea	cx,selmod
	jmp	cx
noahed:	mov	dx,#0x3c3		! Check Chips & Tech. 'clues'
	in	al,dx
	or	al,#0x10
	out	dx,al
	mov	dx,#0x104		
	in	al,dx
	mov	bl,al
	mov	dx,#0x3c3
	in	al,dx
	and	al,#0xef
	out	dx,al
	cmp	bl,[idcandt]
	jne	nocant
	lea	si,dsccandt
	lea	di,mocandt
	lea	cx,selmod
	jmp	cx
nocant:	mov	dx,#0x3d4		! Check Cirrus 'clues'
	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	xor	al,al
	out	dx,al
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	xor	ah,ah
	shl	al,#4
	mov	cx,ax
	mov	al,bh
	shr	al,#4
	add	cx,ax
	shl	cx,#8
	add	cx,#6
	mov	ax,cx
	mov	dx,#0x3c4
	out	dx,ax
	inc	dx
	in	al,dx
	and	al,al
	jnz	nocirr
	mov	al,bh
	out	dx,al
	in	al,dx
	cmp	al,#0x01
	jne	nocirr
	call	rst3d4	
	lea	si,dsccirrus
	lea	di,mocirrus
	lea	cx,selmod
	jmp	cx
rst3d4:	mov	dx,#0x3d4
	mov	al,bl
	xor	ah,ah
	shl	ax,#8
	add	ax,#0x0c
	out	dx,ax
	ret	
nocirr:	call	rst3d4			! Check Everex 'clues'
	mov	ax,#0x7000
	xor	bx,bx
	int	0x10
	cmp	al,#0x70
	jne	noevrx
	shr	dx,#4
	cmp	dx,#0x678
	je	istrid
	cmp	dx,#0x236
	je	istrid
	lea	si,dsceverex
	lea	di,moeverex
	lea	cx,selmod
	jmp	cx
istrid:	lea	cx,ev2tri
	jmp	cx
noevrx:	lea	si,idgenoa		! Check Genoa 'clues'
	xor 	ax,ax
	seg es
	mov	al,[0x37]
	mov	di,ax
	mov	cx,#0x04
	dec	si
	dec	di
l1:	inc	si
	inc	di
	mov	al,(si)
	seg es
	and	al,(di)
	cmp	al,(si)
	loope 	l1
	cmp	cx,#0x00
	jne	nogen
	lea	si,dscgenoa
	lea	di,mogenoa
	lea	cx,selmod
	jmp	cx
nogen:	lea	si,idparadise		! Check Paradise 'clues'
	mov	di,#0x7d
	mov	cx,#0x04
	repe
	cmpsb
	jne	nopara
	lea	si,dscparadise
	lea	di,moparadise
	lea	cx,selmod
	jmp	cx
nopara:	mov	dx,#0x3c4		! Check Trident 'clues'
	mov	al,#0x0e
	out	dx,al
	inc	dx
	in	al,dx
	xchg	ah,al
	mov	al,#0x00
	out	dx,al
	in	al,dx
	xchg	al,ah
	mov	bl,al		! Strange thing ... in the book this wasn't
	and	bl,#0x02	! necessary but it worked on my card which
	jz	setb2		! is a trident. Without it the screen goes
	and	al,#0xfd	! blurred ...
	jmp	clrb2		!
setb2:	or	al,#0x02	!
clrb2:	out	dx,al
	and	ah,#0x0f
	cmp	ah,#0x02
	jne	notrid
ev2tri:	lea	si,dsctrident
	lea	di,motrident
	lea	cx,selmod
	jmp	cx
notrid:	mov	dx,#0x3cd		! Check Tseng 'clues'
	in	al,dx			! Could things be this simple ! :-)
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	mov	ah,al
	mov	al,bl
	out	dx,al
	cmp	ah,#0x55
 	jne	notsen
	lea	si,dsctseng
	lea	di,motseng
	lea	cx,selmod
	jmp	cx
notsen:	mov	dx,#0x3cc		! Check Video7 'clues'
	in	al,dx
	mov	dx,#0x3b4
	and	al,#0x01
	jz	even7
	mov	dx,#0x3d4
even7:	mov	al,#0x0c
	out	dx,al
	inc	dx
	in	al,dx
	mov	bl,al
	mov	al,#0x55
	out	dx,al
	in	al,dx
	dec	dx
	mov	al,#0x1f
	out	dx,al
	inc	dx
	in	al,dx
	mov	bh,al
	dec	dx
	mov	al,#0x0c
	out	dx,al
	inc	dx
	mov	al,bl
	out	dx,al
	mov	al,#0x55
	xor	al,#0xea
	cmp	al,bh
	jne	novid7
	lea	si,dscvideo7
	lea	di,movideo7
selmod:	push	si
	lea	si,msg2
	call	prtstr
	xor	cx,cx
	mov	cl,(di)
	pop	si
	push	si
	push	cx
tbl:	pop	bx
	push	bx
	mov	al,bl
	sub	al,cl
	call	dprnt
	call	spcing
	lodsw
	xchg	al,ah
	call	dprnt
	xchg	ah,al
	push	ax
	mov	al,#0x78
	call	prnt1
	pop	ax
	call	dprnt
	call	docr
	loop	tbl
	pop	cx
	call	docr
	lea	si,msg3
	call	prtstr
	pop	si
	add	cl,#0x80
nonum:	in	al,#0x60	! Quick and dirty...
	cmp	al,#0x82
	jb	nonum
	cmp	al,#0x8b
	je	zero
	cmp	al,cl
	ja	nonum
	jmp	nozero
zero:	sub	al,#0x0a
nozero:	sub	al,#0x80
	dec	al
	xor	ah,ah
	add	di,ax
	inc	di
	push	ax
	mov	al,(di)
	int 	0x10
	pop	ax
	shl	ax,#1
	add	si,ax
	lodsw
	pop	ds
	ret
novid7:	pop	ds	! Here could be code to support standard 80x50,80x30
	mov	ax,#0x5019	
	ret

! Routine that 'tabs' to next col.

spcing:	mov	al,#0x2e
	call	prnt1
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1	
	mov	al,#0x20
	call	prnt1
	ret	

! Routine to print asciiz-string at DS:SI

prtstr:	lodsb
	and	al,al
	jz	fin
	call	prnt1
	jmp	prtstr
fin:	ret

! Routine to print a decimal value on screen, the value to be
! printed is put in al (i.e 0-255). 

dprnt:	push	ax
	push	cx
	mov	ah,#0x00		
	mov	cl,#0x0a
	idiv	cl
	cmp	al,#0x09
	jbe	lt100
	call	dprnt
	jmp	skip10
lt100:	add	al,#0x30
	call	prnt1
skip10:	mov	al,ah
	add	al,#0x30
	call	prnt1	
	pop	cx
	pop	ax
	ret

! Part of above routine, this one just prints ascii al

prnt1:	push	ax
	push	cx
	mov	bh,#0x00
	mov	cx,#0x01
	mov	ah,#0x0e
	int	0x10
	pop	cx
	pop	ax
	ret

! Prints <CR> + <LF>

docr:	push	ax
	push	cx
	mov	bh,#0x00
	mov	ah,#0x0e
	mov	al,#0x0a
	mov	cx,#0x01
	int	0x10
	mov	al,#0x0d
	int	0x10
	pop	cx
	pop	ax
	ret	
; =============== 配置VGA显卡信息 end

; 全局描述符表开始处。描述符表由多个 8 字节长的描述符项组成。这里给出了 3 个描述符项。 
; 第 1 项无用，但须存在。第 2 项是系统代码段描述符，第 3 项是系 
; 统数据段描述符。	
gdt:
	.word	0,0,0,0		! dummy

; 在GDT表之中这里的偏移量是0x08，它是内核代码段选择符的值
	.word	0x07FF		! 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		! base address=0
	.word	0x9A00		! code read/exec ; 代码段为只读、可执行
	.word	0x00C0		! granularity=4096, 386 ; 颗粒度为4096，32位模式

; 在GDT表之中这里的偏移量是0x10，这是内核数据段选择符的值
	.word	0x07FF		! 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		! base address=0
	.word	0x9200		! data read/write
	.word	0x00C0		! granularity=4096, 386

; 指令LIDT的操作数，用于加载中断描述符表寄存器
; 这个操作数一共有六个字节。前2字节是描述符表的字节长度值
; 后4字节是描述符表的32位线性基地址
idt_48:
	.word	0			! idt limit=0
	.word	0,0			! idt base=0L

; 指令LGDT的操作数，用于加载全局表舒服表寄存器，同样也使用6字节
; 头两个字节代表描述符表的长度，后4个字节是描述表的基地址
gdt_48:
	.word	0x800		! gdt limit=2048, 256 GDT entries
	.word	512+gdt,0x9	! gdt base = 0X9xxxx

msg1:		.ascii	"Press <RETURN> to see SVGA-modes available or any other key to continue."
		db	0x0d, 0x0a, 0x0a, 0x00
msg2:		.ascii	"Mode:  COLSxROWS:"
		db	0x0d, 0x0a, 0x0a, 0x00
msg3:		.ascii	"Choose mode by pressing the corresponding number."
		db	0x0d, 0x0a, 0x00
		
idati:		.ascii	"761295520"
idcandt:	.byte	0xa5
idgenoa:	.byte	0x77, 0x00, 0x66, 0x99
idparadise:	.ascii	"VGA="

! Manufacturer:	  Numofmodes:	Mode:

moati:		.byte	0x02,	0x23, 0x33 
moahead:	.byte	0x05,	0x22, 0x23, 0x24, 0x2f, 0x34
mocandt:	.byte	0x02,	0x60, 0x61
mocirrus:	.byte	0x04,	0x1f, 0x20, 0x22, 0x31
moeverex:	.byte	0x0a,	0x03, 0x04, 0x07, 0x08, 0x0a, 0x0b, 0x16, 0x18, 0x21, 0x40
mogenoa:	.byte	0x0a,	0x58, 0x5a, 0x60, 0x61, 0x62, 0x63, 0x64, 0x72, 0x74, 0x78
moparadise:	.byte	0x02,	0x55, 0x54
motrident:	.byte	0x07,	0x50, 0x51, 0x52, 0x57, 0x58, 0x59, 0x5a
motseng:	.byte	0x05,	0x26, 0x2a, 0x23, 0x24, 0x22
movideo7:	.byte	0x06,	0x40, 0x43, 0x44, 0x41, 0x42, 0x45

!			msb = Cols lsb = Rows:

dscati:		.word	0x8419, 0x842c
dscahead:	.word	0x842c, 0x8419, 0x841c, 0xa032, 0x5042
dsccandt:	.word	0x8419, 0x8432
dsccirrus:	.word	0x8419, 0x842c, 0x841e, 0x6425
dsceverex:	.word	0x5022, 0x503c, 0x642b, 0x644b, 0x8419, 0x842c, 0x501e, 0x641b, 0xa040, 0x841e
dscgenoa:	.word	0x5020, 0x642a, 0x8419, 0x841d, 0x8420, 0x842c, 0x843c, 0x503c, 0x5042, 0x644b
dscparadise:	.word	0x8419, 0x842b
dsctrident:	.word 	0x501e, 0x502b, 0x503c, 0x8419, 0x841e, 0x842b, 0x843c
dsctseng:	.word	0x503c, 0x6428, 0x8419, 0x841c, 0x842c
dscvideo7:	.word	0x502b, 0x503c, 0x643c, 0x8419, 0x842c, 0x841c
	
.text
endtext:
.data
enddata:
.bss
endbss:
