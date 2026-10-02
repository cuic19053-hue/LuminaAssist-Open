/**
 * @file TaskListView.ets
 * @module components
 * @description 多任务拆解与协同进度展示卡片（对齐原型 Screen 06）。
 */

import { SystemTaskService } from '../services/SystemTaskService';

export interface UIBackendTask {
  action: string;
  target: string;
  content: string;
  status: 'done' | 'run' | 'pend';
  statusText: string;
}

@Component
export struct TaskListView {
  @Prop tasks: Array<UIBackendTask> = [];

  private handleCardClick(task: UIBackendTask): void {
    const sys = SystemTaskService.getInstance();
    if (task.action === 'call_ride') {
      sys.callRide(task.target);
    } else if (task.action === 'emergency_call' || task.action === 'make_call' || task.action === 'dial') {
      sys.dial(task.target);
    } else if (task.action === 'send_sms') {
      sys.sendSms(task.target, task.content);
    }
  }

  private getActionTitle(action: string, target: string): string {
    switch (action) {
      case 'emergency_call':
      case 'make_call':
      case 'dial':
        return `拨打 ${target} 的电话`;
      case 'send_sms':
        return `发送短信给 ${target}`;
      case 'call_ride':
        return `叫车前往 ${target.length > 0 && target !== 'default' ? target : '目的地'}`;
      case 'medicine_recognition':
        return '药品识别';
      case 'vision_analyze':
        return '物品识别';
      case 'read_screen':
        return '朗读屏幕内容';
      default:
        return `${action} (${target})`;
    }
  }

  build() {
    Column({ space: 10 }) {
      // 头部标题
      Row({ space: 6 }) {
        Text('📋')
          .fontSize(14)
        Text('任务拆解 · TASK LIST')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#8AA09A')
          .letterSpacing(0.5)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 任务列表
      ForEach(this.tasks, (task: UIBackendTask, index: number) => {
        Row({ space: 10 }) {
          // 状态图标
          Stack() {
            if (task.status === 'done') {
              Text('✓')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#15803D')
            } else if (task.status === 'run') {
              Row()
                .width(10)
                .height(10)
                .borderRadius(5)
                .backgroundColor('#F59E0B')
            } else {
              Row()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor('#8AA09A')
            }
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor(
            task.status === 'done' ? '#EAFAF0' : (task.status === 'run' ? '#FFF6E5' : '#F0F6F3')
          )

          // 任务内容
          Column({ space: 2 }) {
            Text(this.getActionTitle(task.action, task.target))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(task.status === 'pend' ? '#8AA09A' : '#182925')

            if (task.content.length > 0) {
              Text(task.content)
                .fontSize(12)
                .fontColor('#48605A')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 尾端状态
          Text(task.statusText)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(
              task.status === 'done' ? '#04785C' : (task.status === 'run' ? '#8A6100' : '#8AA09A')
            )
        }
        .width('100%')
        .padding(10)
        .borderRadius(12)
        .backgroundColor('#F4FAF7')
        .opacity(task.status === 'pend' ? 0.65 : 1.0)
        .onClick(() => {
          this.handleCardClick(task);
        })
      }, (task: UIBackendTask, index: number) => `${index}_${task.action}_${task.status}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E2ECE7' })
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}
