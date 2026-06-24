"""
Business Logic for Todo Application
Handles all todo-related operations and data management
"""

from datetime import datetime
from typing import Optional, List, Dict


class TodoManager:
    """Manages todo items with CRUD operations"""
    
    def __init__(self):
        """Initialize the TodoManager with empty storage"""
        self.todos = {}
        self.next_id = 1
    
    def create_todo(self, title: str, description: str = "") -> Dict:
        """
        Create a new todo item
        
        Args:
            title: The title of the todo
            description: Optional description
            
        Returns:
            Dictionary containing the created todo
        """
        if not title or not title.strip():
            raise ValueError("Title cannot be empty")
        
        todo = {
            "id": self.next_id,
            "title": title.strip(),
            "description": description.strip(),
            "completed": False,
            "created_at": datetime.utcnow().isoformat(),
            "updated_at": datetime.utcnow().isoformat()
        }
        
        self.todos[self.next_id] = todo
        self.next_id += 1
        
        return todo
    
    def get_todo(self, todo_id: int) -> Optional[Dict]:
        """
        Get a specific todo by ID
        
        Args:
            todo_id: The ID of the todo to retrieve
            
        Returns:
            Todo dictionary if found, None otherwise
        """
        return self.todos.get(todo_id)
    
    def get_all_todos(self) -> List[Dict]:
        """
        Get all todos
        
        Returns:
            List of all todo dictionaries
        """
        return list(self.todos.values())
    
    def update_todo(self, todo_id: int, title: Optional[str] = None, 
                   description: Optional[str] = None, 
                   completed: Optional[bool] = None) -> Optional[Dict]:
        """
        Update an existing todo
        
        Args:
            todo_id: The ID of the todo to update
            title: New title (optional)
            description: New description (optional)
            completed: New completion status (optional)
            
        Returns:
            Updated todo dictionary if found, None otherwise
        """
        todo = self.todos.get(todo_id)
        
        if not todo:
            return None
        
        if title is not None:
            if not title.strip():
                raise ValueError("Title cannot be empty")
            todo["title"] = title.strip()
        
        if description is not None:
            todo["description"] = description.strip()
        
        if completed is not None:
            if not isinstance(completed, bool):
                raise ValueError("Completed must be a boolean")
            todo["completed"] = completed
        
        todo["updated_at"] = datetime.utcnow().isoformat()
        
        return todo
    
    def delete_todo(self, todo_id: int) -> bool:
        """
        Delete a todo
        
        Args:
            todo_id: The ID of the todo to delete
            
        Returns:
            True if deleted, False if not found
        """
        if todo_id in self.todos:
            del self.todos[todo_id]
            return True
        return False
    
    def get_completed_todos(self) -> List[Dict]:
        """
        Get all completed todos
        
        Returns:
            List of completed todo dictionaries
        """
        return [todo for todo in self.todos.values() if todo["completed"]]
    
    def get_pending_todos(self) -> List[Dict]:
        """
        Get all pending (not completed) todos
        
        Returns:
            List of pending todo dictionaries
        """
        return [todo for todo in self.todos.values() if not todo["completed"]]
    
    def count_todos(self) -> Dict[str, int]:
        """
        Get count of todos by status
        
        Returns:
            Dictionary with total, completed, and pending counts
        """
        return {
            "total": len(self.todos),
            "completed": len(self.get_completed_todos()),
            "pending": len(self.get_pending_todos())
        }
