; File and directory helpers of the llvm16 target with the mos-c64 profile target, as upstream prog8c-llvm emits them
; (extracted by tools/extract_llvmrt.py from its output for runtime/alldisk.p8).
; tools/gen_llvmrt.py turns this file into src/llvmrt.p8.

@.file.mode.rb = private unnamed_addr constant [3 x i8] c"rb\00"
@.file.read_stream = internal global ptr null
@.file.mode.wb = private unnamed_addr constant [3 x i8] c"wb\00"
@.file.write_stream = internal global ptr null

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
  call i16 @fclose(ptr %previous)
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
  call i16 @fclose(ptr %file)
  store ptr null, ptr %stream
  br label %done

done:
  ret void
}

define internal i8 @.file.save(i1 %raw, ptr %name, ptr %start, i16 %size) {
entry:
  %file = call ptr @fopen(ptr %name, ptr @.file.mode.wb)
  %failed = icmp eq ptr %file, null
  br i1 %failed, label %fail, label %opened

opened:
  br i1 %raw, label %write, label %header

header:
  %address = ptrtoint ptr %start to i16
  %lsb = and i16 %address, 255
  call i16 @fputc(i16 %lsb, ptr %file)
  %shifted = lshr i16 %address, 8
  %msb = and i16 %shifted, 255
  call i16 @fputc(i16 %msb, ptr %file)
  br label %write

write:
  %written = call i16 @fwrite(ptr %start, i16 1, i16 %size, ptr %file)
  %complete = icmp eq i16 %written, %size
  %closed = call i16 @fclose(ptr %file)
  %flushed = icmp eq i16 %closed, 0
  %ok = and i1 %complete, %flushed
  %result = zext i1 %ok to i8
  ret i8 %result

fail:
  ret i8 0
}

define internal i16 @.file.read.byte() {
entry:
  %file = load ptr, ptr @.file.read_stream
  %open = icmp ne ptr %file, null
  br i1 %open, label %read, label %none

read:
  %char = call i16 @fgetc(ptr %file)
  %end = icmp slt i16 %char, 0
  br i1 %end, label %none, label %got

got:
  %value = or i16 %char, 256
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
  %char = zext i8 %byte to i16
  %written = call i16 @fputc(i16 %char, ptr %file)
  %ok = icmp sge i16 %written, 0
  %result = zext i1 %ok to i8
  ret i8 %result

fail:
  ret i8 0
}

declare ptr @fopen(ptr, ptr)
declare i16 @fclose(ptr)
declare i16 @fputc(i16, ptr)
declare i16 @fwrite(ptr, i16, i16, ptr)
declare i16 @fgetc(ptr)
