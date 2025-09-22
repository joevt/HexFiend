//
//  HFTemplateNode.m
//  HexFiend_2
//
//  Created by Kevin Wojniak on 1/7/18.
//  Copyright © 2018 ridiculous_fish. All rights reserved.
//

#import "HFTemplateNode.h"

@interface HFTemplateNode ()

@property (weak) HFTemplateNode *parent;

@end

@implementation HFTemplateNode

- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value parent:(HFTemplateNode *)parent {
    if ((self = [super init]) != nil) {
        _label = label;
        _value = value;
        _parent = parent;
        if (_parent) {
            [self.parent.children addObject:self];
        }
    }
    return self;
}

- (instancetype)initGroupWithLabel:(NSString *)label parent:(HFTemplateNode *)parent {
    if ((self = [super init]) != nil) {
        _label = label;
        _isGroup = YES;
        _parent = parent;
        _children = [NSMutableArray array];
        if (_parent) {
            [self.parent.children addObject:self];
        }
    }
    return self;
}

- (BOOL)isSection {
    return self.isGroup && self.label != nil;
}

- (void)mergeRanges {
    if (
        !self.parent || // the root doesn't have a parent to update
        !self.parent.parent // updating the root is unnecessary
    ) {
        return;
    }

    //id firstObject = [myArray objectAtIndex:0];
    
    {
        HFRangeWrapper * childFirst = [self.ranges firstObject];
        HFRangeWrapper * parentLast = [self.parent.ranges lastObject];
        if (childFirst.HFRange.location > HFMaxRange(parentLast.HFRange)) {
            [self.parent.ranges addObjectsFromArray:self.ranges];
            return;
        }
        if (childFirst.HFRange.location == HFMaxRange(parentLast.HFRange)) {
            HFRange newRange = parentLast.HFRange;
            newRange.length += childFirst.HFRange.length;
            [self.parent.ranges replaceObjectAtIndex:self.parent.ranges.count - 1 withObject:[HFRangeWrapper withRange:newRange]];
            [self.parent.ranges replaceObjectsInRange:NSMakeRange(self.parent.ranges.count, 0) withObjectsFromArray:self.ranges range:NSMakeRange(1, self.ranges.count - 1)];
            return;
        }
    }

    {
        HFRangeWrapper * parentFirst = [self.parent.ranges firstObject];
        HFRangeWrapper * childLast   = [self.ranges lastObject];
        if (parentFirst.HFRange.location > HFMaxRange(childLast.HFRange)) {
            [self.parent.ranges replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:self.ranges];
            return;
        }
        if (parentFirst.HFRange.location == HFMaxRange(childLast.HFRange)) {
            HFRange newRange = childLast.HFRange;
            newRange.length += parentFirst.HFRange.length;
            [self.parent.ranges replaceObjectAtIndex:0 withObject:[HFRangeWrapper withRange:newRange]];
            [self.parent.ranges replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:self.ranges range:NSMakeRange(0, self.ranges.count - 1)];
            return;
        }
    }

    NSUInteger rpndx = 0;
    NSUInteger rcndx = 0;
    NSUInteger rplen = self.parent.ranges.count;
    NSUInteger rclen = self.ranges.count;
    HFRangeWrapper * rpobj;
    HFRangeWrapper * rcobj;

    NSMutableArray * array = [[NSMutableArray alloc] initWithCapacity:rplen + rclen];

    NSUInteger i;

    while (rpndx < rplen || rcndx < rclen) {
        if (rcndx == rclen) {
            [array replaceObjectsInRange:NSMakeRange(array.count, 0) withObjectsFromArray:self.parent.ranges range:NSMakeRange(rpndx, rplen - rpndx)];
            rpndx = rplen;
        } else if (rcndx < rclen) {
            rcobj = [self.ranges objectAtIndex:rcndx];
            unsigned long long rcstart = rcobj.HFRange.location;
            for (i = rpndx; i < rplen && HFMaxRange((rpobj = [self.parent.ranges objectAtIndex:i]).HFRange) < rcstart; i++);
            if (i > rpndx) {
                [array replaceObjectsInRange:NSMakeRange(array.count, 0) withObjectsFromArray:self.parent.ranges range:NSMakeRange(rpndx, i - rpndx)];
                rpndx = i;
            }
        }

        if (rpndx == rplen) {
            [array replaceObjectsInRange:NSMakeRange(array.count, 0) withObjectsFromArray:self.ranges range:NSMakeRange(rcndx, rclen - rcndx)];
            rcndx = rclen;
        } else if (rpndx < rplen) {
            rpobj = [self.parent.ranges objectAtIndex:rpndx];
            unsigned long long rpstart = rpobj.HFRange.location;
            for (i = rcndx; i < rclen && HFMaxRange((rcobj = [self.ranges objectAtIndex:i]).HFRange) < rpstart; i++);
            if (i > rcndx) {
                [array replaceObjectsInRange:NSMakeRange(array.count, 0) withObjectsFromArray:self.ranges range:NSMakeRange(rcndx, i - rcndx)];
                rcndx = i;
            }
        }

        if (rpndx < rplen && rcndx < rclen) {
            if (HFTouchingRange(rpobj.HFRange, rcobj.HFRange)) {
                HFRange temp = HFUnionRange(rpobj.HFRange, rcobj.HFRange);
                rpndx++;
                rcndx++;
                for (; rpndx < rplen && HFTouchingRange(temp, (rpobj = [self.parent.ranges objectAtIndex:rpndx]).HFRange); rpndx++) {
                    temp = HFUnionRange(temp, rpobj.HFRange);
                }
                for (; rcndx < rclen && HFTouchingRange(temp, (rcobj = [self.ranges objectAtIndex:rcndx]).HFRange); rcndx++) {
                    temp = HFUnionRange(temp, rcobj.HFRange);
                }
                [array addObject:[HFRangeWrapper withRange:temp]];
            }
        }
    }

    self.parent.ranges = array;
}

- (void)addRange:(unsigned long long)location length:(unsigned long long)length {
    HFRange range = HFRangeMake(location, length);
    self.ranges = [HFRangeWrapper withRanges:&range count:1];
    if (!self.isGroup)
        [self mergeRanges];
}

@end
