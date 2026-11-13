; File and directory helpers of the llvm64 target, as upstream prog8c-llvm emits them
; (extracted from its output for a program that uses all of diskio; arm64 macOS).
; tools/gen_llvmrt.py turns this file into src/llvmrt.p8.

@.diskio.dot = private unnamed_addr constant [2 x i8] c".\00"
@.diskio.dotdot = private unnamed_addr constant [3 x i8] c"..\00"
@.diskio.format.dir = private unnamed_addr constant [8 x i8] c"dir\09%s\0A\00"
@.file.mode.rb = private unnamed_addr constant [3 x i8] c"rb\00"
@.diskio.format.file = private unnamed_addr constant [8 x i8] c"%ld\09%s\0A\00"
@.file.read_stream = internal global ptr null
@.file.mode.wb = private unnamed_addr constant [3 x i8] c"wb\00"
@.file.write_stream = internal global ptr null
@.sys.curdir.buf = internal global [4096 x i8] zeroinitializer

define internal i32 @.diskio.compare(ptr %first, ptr %second) {
entry:
  %a = load ptr, ptr %first
  %b = load ptr, ptr %second
  %order = call i32 @strcmp(ptr %a, ptr %b)
  ret i32 %order
}

define internal i8 @.diskio.list(i8 %kind) {
entry:
  %names_slot = alloca ptr
  %count_slot = alloca i64
  store ptr null, ptr %names_slot
  store i64 0, ptr %count_slot
  %dir = call ptr @opendir(ptr @.diskio.dot)
  %failed = icmp eq ptr %dir, null
  br i1 %failed, label %fail, label %read

read:
  %dirent = call ptr @readdir(ptr %dir)
  %end = icmp eq ptr %dirent, null
  br i1 %end, label %sort, label %name

name:
  %entry_name = getelementptr inbounds i8, ptr %dirent, i32 21
  %dot = call i32 @strcmp(ptr %entry_name, ptr @.diskio.dot)
  %is_dot = icmp eq i32 %dot, 0
  %dotdot = call i32 @strcmp(ptr %entry_name, ptr @.diskio.dotdot)
  %is_dotdot = icmp eq i32 %dotdot, 0
  %skip = or i1 %is_dot, %is_dotdot
  br i1 %skip, label %read, label %keep

keep:
  %count = load i64, ptr %count_slot
  %names = load ptr, ptr %names_slot
  %grown_count = add i64 %count, 1
  %bytes = mul i64 %grown_count, 8
  %grown = call ptr @realloc(ptr %names, i64 %bytes)
  %full = icmp eq ptr %grown, null
  br i1 %full, label %sort, label %copy

copy:
  store ptr %grown, ptr %names_slot
  %name_copy = call ptr @strdup(ptr %entry_name)
  %lost = icmp eq ptr %name_copy, null
  br i1 %lost, label %sort, label %add

add:
  %slot = getelementptr inbounds ptr, ptr %grown, i64 %count
  store ptr %name_copy, ptr %slot
  store i64 %grown_count, ptr %count_slot
  br label %read

sort:
  call i32 @closedir(ptr %dir)
  %total = load i64, ptr %count_slot
  %list = load ptr, ptr %names_slot
  call void @qsort(ptr %list, i64 %total, i64 8, ptr @.diskio.compare)
  br label %loop

loop:
  %index = phi i64 [ 0, %sort ], [ %next_index, %next ]
  %done = icmp eq i64 %index, %total
  br i1 %done, label %finish, label %show

show:
  %at = getelementptr inbounds ptr, ptr %list, i64 %index
  %file = load ptr, ptr %at
  %sub = call ptr @opendir(ptr %file)
  %is_dir = icmp ne ptr %sub, null
  br i1 %is_dir, label %directory, label %other

directory:
  call i32 @closedir(ptr %sub)
  %want_dirs = icmp ne i8 %kind, 2
  br i1 %want_dirs, label %print_dir, label %next

print_dir:
  call i32 (ptr, ...) @printf(ptr @.diskio.format.dir, ptr %file)
  br label %next

other:
  %want_files = icmp ne i8 %kind, 1
  br i1 %want_files, label %measure, label %next

measure:
  %stream = call ptr @fopen(ptr %file, ptr @.file.mode.rb)
  %opened = icmp ne ptr %stream, null
  br i1 %opened, label %size, label %print_file

size:
  call i32 @fseek(ptr %stream, i64 0, i32 2)
  %length = call i64 @ftell(ptr %stream)
  call i32 @fclose(ptr %stream)
  br label %print_file

print_file:
  %file_size = phi i64 [ 0, %measure ], [ %length, %size ]
  call i32 (ptr, ...) @printf(ptr @.diskio.format.file, i64 %file_size, ptr %file)
  br label %next

next:
  call void @free(ptr %file)
  %next_index = add i64 %index, 1
  br label %loop

finish:
  call void @free(ptr %list)
  ret i8 1

fail:
  ret i8 0
}

define internal i8 @.file.open(ptr %name, ptr %mode, ptr %stream) {
entry:
  %file = call ptr @fopen(ptr %name, ptr %mode)
  %failed = icmp eq ptr %file, null
  br i1 %failed, label %fail, label %opened

opened:
  %previous = load ptr, ptr %stream
  %open = icmp ne ptr %previous, null
  br i1 %open, label %close, label %keep

close:
  call i32 @fclose(ptr %previous)
  br label %keep

keep:
  store ptr %file, ptr %stream
  ret i8 1

fail:
  ret i8 0
}

define internal void @.file.close(ptr %stream) {
entry:
  %file = load ptr, ptr %stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %close, label %done

close:
  call i32 @fclose(ptr %file)
  store ptr null, ptr %stream
  br label %done

done:
  ret void
}

define internal i32 @.file.fseek(ptr %file, i64 %offset, i32 %origin) {
entry:
  %before = call i64 @ftell(ptr %file)
  %status = call i32 @fseek(ptr %file, i64 %offset, i32 %origin)
  %failed = icmp ne i32 %status, 0
  br i1 %failed, label %restore, label %done

restore:
  call i32 @fseek(ptr %file, i64 %before, i32 0)
  ret i32 %status

done:
  ret i32 %status
}

define internal i8 @.file.seek(i32 %position) {
entry:
  %file = load ptr, ptr @.file.read_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %seek, label %fail

seek:
  %offset = sext i32 %position to i64
  %status = call i32 @.file.fseek(ptr %file, i64 %offset, i32 0)
  %ok = icmp eq i32 %status, 0
  %result = zext i1 %ok to i8
  ret i8 %result

fail:
  ret i8 0
}

define internal i32 @.file.tell() {
entry:
  %file = load ptr, ptr @.file.read_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %tell, label %none

tell:
  %position = call i64 @ftell(ptr %file)
  %valid = icmp sge i64 %position, 0
  %known = select i1 %valid, i64 %position, i64 0
  %result = trunc i64 %known to i32
  ret i32 %result

none:
  ret i32 0
}

define internal i32 @.file.size() {
entry:
  %file = load ptr, ptr @.file.read_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %measure, label %none

measure:
  %position = call i64 @ftell(ptr %file)
  %seekable = icmp sge i64 %position, 0
  br i1 %seekable, label %end, label %none

end:
  call i32 @fseek(ptr %file, i64 0, i32 2)
  %size = call i64 @ftell(ptr %file)
  call i32 @fseek(ptr %file, i64 %position, i32 0)
  %valid = icmp sge i64 %size, 0
  %known = select i1 %valid, i64 %size, i64 0
  %result = trunc i64 %known to i32
  ret i32 %result

none:
  ret i32 0
}

define internal i8 @.file.save(i1 %raw, ptr %name, ptr %start, i64 %size) {
entry:
  %file = call ptr @fopen(ptr %name, ptr @.file.mode.wb)
  %failed = icmp eq ptr %file, null
  br i1 %failed, label %fail, label %opened

opened:
  br i1 %raw, label %write, label %header

header:
  %address = ptrtoint ptr %start to i64
  %low = trunc i64 %address to i32
  %lsb = and i32 %low, 255
  call i32 @fputc(i32 %lsb, ptr %file)
  %shifted = lshr i32 %low, 8
  %msb = and i32 %shifted, 255
  call i32 @fputc(i32 %msb, ptr %file)
  br label %write

write:
  %written = call i64 @fwrite(ptr %start, i64 1, i64 %size, ptr %file)
  %complete = icmp eq i64 %written, %size
  %closed = call i32 @fclose(ptr %file)
  %flushed = icmp eq i32 %closed, 0
  %ok = and i1 %complete, %flushed
  %result = zext i1 %ok to i8
  ret i8 %result

fail:
  ret i8 0
}

define internal ptr @.file.load(ptr %name, ptr %address, i1 %raw) {
entry:
  %nowhere = icmp eq ptr %address, null
  br i1 %nowhere, label %fail, label %open

open:
  %file = call ptr @fopen(ptr %name, ptr @.file.mode.rb)
  %failed = icmp eq ptr %file, null
  br i1 %failed, label %fail, label %header

header:
  br i1 %raw, label %read, label %skip

skip:
  call i32 @fgetc(ptr %file)
  %second = call i32 @fgetc(ptr %file)
  %truncated = icmp slt i32 %second, 0
  br i1 %truncated, label %unloaded, label %read

read:
  %start = call i64 @ftell(ptr %file)
  call i32 @fseek(ptr %file, i64 0, i32 2)
  %end = call i64 @ftell(ptr %file)
  %unknown = icmp slt i64 %end, %start
  br i1 %unknown, label %unloaded, label %measured

measured:
  call i32 @fseek(ptr %file, i64 %start, i32 0)
  %rest = sub i64 %end, %start
  %count = call i64 @fread(ptr %address, i64 1, i64 %rest, ptr %file)
  %next = getelementptr i8, ptr %address, i64 %count
  call i32 @fgetc(ptr %file)
  br label %done

done:
  %error = call i32 @ferror(ptr %file)
  call i32 @fclose(ptr %file)
  %broken = icmp ne i32 %error, 0
  br i1 %broken, label %fail, label %loaded

loaded:
  ret ptr %next

unloaded:
  call i32 @fclose(ptr %file)
  br label %fail

fail:
  ret ptr null
}

define internal i16 @.file.read.byte() {
entry:
  %file = load ptr, ptr @.file.read_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %read, label %none

read:
  %char = call i32 @fgetc(ptr %file)
  %end = icmp slt i32 %char, 0
  br i1 %end, label %none, label %got

got:
  %byte = trunc i32 %char to i16
  %value = or i16 %byte, 256
  ret i16 %value

none:
  ret i16 0
}

define internal i8 @.file.write.byte(i8 %byte) {
entry:
  %file = load ptr, ptr @.file.write_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %write, label %fail

write:
  %char = zext i8 %byte to i32
  %written = call i32 @fputc(i32 %char, ptr %file)
  %ok = icmp sge i32 %written, 0
  %result = zext i1 %ok to i8
  ret i8 %result

fail:
  ret i8 0
}

declare ptr @opendir(ptr)
declare ptr @readdir(ptr)
declare i32 @printf(ptr, ...)
declare i32 @strcmp(ptr, ptr)
declare ptr @realloc(ptr, i64)
declare ptr @strdup(ptr)
declare i32 @closedir(ptr)
declare void @qsort(ptr, i64, i64, ptr)
declare ptr @fopen(ptr, ptr)
declare i32 @fseek(ptr, i64, i32)
declare i64 @ftell(ptr)
declare i32 @fclose(ptr)
declare void @free(ptr)
declare i32 @fputc(i32, ptr)
declare i64 @fwrite(ptr, i64, i64, ptr)
declare i32 @fgetc(ptr)
declare i64 @fread(ptr, i64, i64, ptr)
declare i32 @ferror(ptr)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
